# Package to process the inline structure of Markdown.

package Markdown::Perl::Inlines;

use strict;
use warnings;
use utf8;
use feature ':5.24';

use English;
use List::MoreUtils 'first_index', 'last_index';
use List::Util 'min';
use Markdown::Perl::InlineTree ':all';
use Markdown::Perl::Util 'normalize_label';

our $VERSION = 0.01;



# Everywhere here, $that is a Markdown::Perl instance that we carry everywhere
# because it contains the options that we are using.
sub render {
  my ($that, @lines) = @_;

  my $text = join("\n", @lines);
  my $tree = find_code_and_tag_runs($that, $text);

  # At this point, @runs contains only 'text',  'code', or 'link' elements, that
  # can’t have any children (yet).

  $tree->map(sub { process_char_escaping($that, $_) });

  # At this point, @runs can also contain 'literal' elements, that don’t have
  # children.

  process_links($that, $tree, 0, 0);  # We start at the beginning of the first node.
  process_images($that, $tree);

  # Now, there are more link elements and they can have children instead of
  # content.

  process_styles($that, $tree);

  # At this point we have added the emphasis, strong emphasis, etc. in the tree.

  my $out = $tree->render_html();

  return $out;
}

# TODO: share these regex with Perl.pm (but note that we are not matching the
# open and close < > characters here).
my $html_tag_name_re = qr/[a-zA-Z][-a-zA-Z0-9]*/;
my $html_attribute_name_re = qr/[a-zA-Z_:][-a-zA-Z0-9_.:]*/;
my $html_space_re = qr/\n[ \t]*|[ \t][ \t]*\n?[ \t]*/;  # Spaces, tabs, and up to one line ending.
my $opt_html_space_re = qr/[ \t]*\n?[ \t]*/;  # Optional spaces.
my $html_attribute_value_re = qr/[^ \t\n"'=<>`]+|'[^']*'|"[^"]*"/;
my $html_attribute_re = qr/${html_space_re}${html_attribute_name_re}(?:${opt_html_space_re}=${opt_html_space_re}${html_attribute_value_re})?/;

my $html_open_tag_re = qr/${html_tag_name_re}${html_attribute_re}*${opt_html_space_re}\/?/;
my $html_close_tag_re = qr/\/${html_tag_name_re}${opt_html_space_re}/;
my $html_comment_re = qr/!--|!---|!--.*?--/s;
my $html_proc_re = qr/\?.*?\?/s;
my $html_decl_re = qr/![a-zA-Z].*?/s;
my $html_cdata_re = qr/!\[CDATA\[.*?\]\]/s;

my $html_tag_re = qr/${html_open_tag_re}|${html_close_tag_re}|${html_comment_re}|${html_proc_re}|${html_decl_re}|${html_cdata_re}/;

# Bug: there is a bug in that backslash escapes don’t work inside autolinks. But
# we can turn our autolinks into full-links later (where the escape should
# work). However, the spec does not test this corner case so we’re fine.

sub find_code_and_tag_runs {
  my ($that, $text) = @_;

  my $tree = Markdown::Perl::InlineTree->new();

  # We match code-spans and autolinks first as they bind strongest. Raw HTML
  # should be here too, but we don’t support it yet.
  # https://spec.commonmark.org/0.30/#code-spans
  # TODO: https://spec.commonmark.org/0.30/#autolinks
  # TODO: https://spec.commonmark.org/0.30/#raw-html
  # while ($text =~ m/(?<code>\`+)|(?<html>\<)/g) {
  # We are manually handling the backslash escaping here because they are not
  # interpreted inside code blocks. We will then process all the others
  # afterward.
  while ($text =~ m/(?<! \\) (?<backslashes> (?:\\\\)*) (?: (?<code>\`+) | < )/gx) {
    my ($start_before, $start_after) =
        ($LAST_MATCH_START[0] + length($+{backslashes}), $LAST_MATCH_END[0]);
    if ($+{code}) {
      my $fence = $+{code};
      # We’re searching for a fence of the same length, without any backtick
      # before or after.
      if ($text =~ m/(?<!\`)${fence}(?!\`)/gc) {
        my ($end_before, $end_after) = ($LAST_MATCH_START[0], $LAST_MATCH_END[0]);
        $tree->push(new_text(substr($text, 0, $start_before)))
            if $start_before > 0;
        $tree->push(new_code(substr($text, $start_after, ($end_before - $start_after))));
        substr $text, 0, $end_after, '';  # This resets pos($text) as we want it to.
      }  # in the else clause, pos($text) == $start_after (because of the /c modifier).
    } else {
      # We matched a single < character.
      my $re = $that->autolinks_regex;
      my $email_re = $that->autolinks_email_regex;
      # We’re not using /gc in these to regex because this confuses the ProhibitUnusedCapture
      # PerlCritic policy. Anyway, as we are always resetting pos() in case of
      # successful match, it’s not important to update it.
      if ($text =~ m/\G(?<link>${re})>/) {
        $tree->push(new_text(substr($text, 0, $start_before)))
            if $start_before > 0;
        $tree->push(new_link($+{link}, type=> 'autolink', target => $+{link}));
        substr $text, 0, $+[0], '';  # This resets pos($text) as we want it to.
      } elsif ($text =~ m/\G(?<link>${email_re})>/) {
        $tree->push(new_text(substr($text, 0, $start_before)))
            if $start_before > 0;
        $tree->push(new_link($+{link}, type => 'autolink', target => 'mailto:'.$+{link}));
        substr $text, 0, $+[0], '';  # This resets pos($text) as we want it to.
      } elsif ($text =~ m/\G(?:${html_tag_re})>/) {
        # This resets pos($text) as we want it to.
        $tree->push(new_text(substr($text, 0, $start_before, '')))
            if $start_before > 0;
        $tree->push(new_html(substr($text, 0, $LAST_MATCH_END[0] - $start_before, '')));
      }
    }
  }
  $tree->push(new_text($text)) if $text;

  return $tree;
}

sub process_char_escaping {
  my ($that, $node) = @_;

  # This is executed after
  if ($node->{type} eq 'code' || $node->{type} eq 'link') {
    # At this stage, link nodes are only autolinks, in which back-slash escaping
    # is not processed.
    return $node;
  } elsif ($node->{type} eq 'text') {
    # TODO: with the current code for map, this could just be @nodes.
    my $new_tree = Markdown::Perl::InlineTree->new();
    # TODO: make this regex configurable (the set of characters that can be
    # escaped). Note that the regex has to be updated in Perl.pm unescape_char
    # method too.
    while ($node->{content} =~ m/\\(\p{PosixPunct})/g) {
      # Literal parsing is OK here (even if we will later create laber reference
      # which distinguish between escaped and non-escaped literals) because we
      # can always invert it (and it makes the rest of the processing be much
      # simpler because we don’t need to check whether we have escaped text or
      # not).
      $new_tree->push(new_text(substr $node->{content}, 0, $LAST_MATCH_START[0]))
          if $LAST_MATCH_START[0] > 0;
      $new_tree->push(new_literal($1));
      substr $node->{content}, 0, $LAST_MATCH_END[0], '';  # This resets pos($node->{content}) as we want it to.
    }
    $new_tree->push($node) if $node->{content};
    return $new_tree;
  } elsif ($node->{type} eq 'html') {
    return $node;
  } else {
    die 'Unexpected node type in process_char_escaping: '.$node->{type};
  }
}

# We find all the links in the tree, starting at the child $child_start and its
# offset $text_start. If the bounds are set, then we don’t investigate links
# that starts further than this bound.
#
# We are not implementing the recommended parsing strategy from the spec:
# https://spec.commonmark.org/0.30/#phase-2-inline-structure
# Instead, we are doing a more straight-forward algorithm, that is probably
# slower but easier to extend.
#
# Overall, this methods implement this whole section of the spec:
# https://spec.commonmark.org/0.30/#links
sub process_links {
  my ($that, $tree, $child_start, $text_start, $start_child_bound, $start_text_bound) = @_;

  my @open =
      $tree->find_in_text(qr/(?<!!)\[/, $child_start, $text_start, $start_child_bound, $start_text_bound);
  return unless @open;
  # TODO: here type is always link, remove this object.
  my $type = (($open[2] - $open[1]) > 1) ? 'img' : 'link';
  # TODO: add an argument here that recurse into sub-trees and returns false if
  # we cross a link element. However, at this stage, the only links that we
  # could find would be autolinks. Although it would make sense that the spec
  # disallow such elements (because it does not make sense in the resulting
  # HTML), the current CommonMark implementation accepts that:
  # https://spec.commonmark.org/dingus/?text=%5Bbar%3Chttp%3A%2F%2Ftest.fr%3Ebaz%5D(%2Fbaz)%0A%0A
  # Maybe we want to fix this bug in our implementation.
  my @close = $tree->find_balanced_in_text(qr/\[/, qr/\]/, $open[0], $open[2]);
  if (@close) {
    # We found something that could be a link, now let’s see if it contains a
    # link (if so, we won’t process the current one).
    if (my @ret = process_links($that, $tree, $open[0], $open[2], $close[0], $close[1])) {
      # We found a link within our bounds, so we don’t create a new link around
      # it. But we do create an image. To do so, we restart our current
      # processing as we need to recompute the coordinate of the closing
      # brackets (and also, there might be other links to process within these
      # bounds).
      if ($type eq  'img') {
        return process_links($that, $tree, @open[0, 1], $start_child_bound, $start_text_bound);
      }
      # If we are a top-level call we try again after the end of the
      # inner-most link found (which was necessarily the left-most valid link.
      # If we are not the top-level call, we just propagate that bound.
      return @ret if defined $start_child_bound;
      process_links($that, $tree, @ret);
      return;  # For top-level calls, we don’t care about the return value.
    } else {
      # We have a candidate link and no internal links, so we try to look at its
      # destination.
      # It’s unclear in the spec what happens in the case when a link
      # destination crosses the boundary of an enclosing candidate link. We
      # assume that the inner one is defined by the link text and not by the
      # destination.

      my @text_span = ($open[0], $open[2], $close[0], $close[1]);
      my %target = find_link_destination_and_title($that, $tree, $close[0], $close[2], @text_span);
      if (%target) {
        my $text_tree = $tree->extract(@text_span);
        my (undef, $dest_node_index) =
            $tree->extract($open[0], $open[1], $open[0] + 1, 1);
        my $link = new_link($text_tree, type => $type, %target);
        $tree->insert($dest_node_index, $link);
        # If we are not a top-level call, we return the coordinate where to
        # start looking again for a link.
        return ($dest_node_index + 1, 0) if defined $start_child_bound;
        # If we are a top-level call, we directly start the search at these
        # coordinates.
        process_links($that, $tree, $dest_node_index + 1, 0);
        return;  # For top-level calls, we don’t care about the return value.
      } else {
        # We could not match a link target, so this is not a link at all.
        # We continue the search just after our initial opening bracket.
        # We do the same call whether or not we are a top-level call.
        return process_links($that, $tree, $open[0], $open[2],
          $start_child_bound, $start_text_bound);
      }
    }
  } else {
    # Our open bracket was unmatched. This necessarily means that we are in the
    # unbounded case (as, otherwise we are within a balanced pair of brackets).
    die 'Unexpected bounded call to process_links with unbalanced brackets'
        if defined $start_child_bound;
    # We continue to search starting just after the open bracket that we found.
    process_links($that, $tree, $open[0], $open[2]);
    return;  # For top-level calls, we don’t care about the return value.
  }
}

sub process_images {
  my ($that, $tree) = @_;

  my @pos = (0, 0);
  while (my @open = $tree->find_in_text(qr/!\[/, @pos)) {
    my @close = $tree->find_balanced_in_text(qr/\[/, qr/\]/, $open[0], $open[2]);
    my @text_span = ($open[0], $open[2], $close[0], $close[1]);
    my %target = find_link_destination_and_title($that, $tree, $close[0], $close[2], @text_span);
    if (%target) {
      my $text_tree = $tree->extract(@text_span);
      my (undef, $dest_node_index) =
          $tree->extract($open[0], $open[1], $open[0] + 1, 1);
      my $link = new_link($text_tree, type => 'img', %target);
      $tree->insert($dest_node_index, $link);
      @pos = ($dest_node_index + 1, 0);
    } else {
      @pos = ($open[0], $open[2]);
    }
  }

  for my $n (@{$tree->{children}}) {
    if ($n->{type} eq 'link' && $n->{linktype} ne 'autolink') {
      process_images($that, $n->{subtree});
    }
  }
}

# @text_span is the span of the link definition text, used in case we have a
# collapsed link reference call.
sub find_link_destination_and_title {
  my ($that, $tree, $child_start, $text_start, @text_span) = @_;
  # We assume that the beginning of the link destination must be just after the
  # link text and in the same child, as there can be no other constructs
  # in-between.
  # TODO: For now we only look at a single element.
  # TODO: this is a very very partial treatment of the link destination.
  # We need to support more formatting and the case where there are Literal
  # elements in the link. The spec does not say what happens if there are
  # other type of elements in the link destination like, stuff that looks like
  # code for example (in practice, CommonMark will not process their content).
  # So let’s not care too much...
  # TODO: we are not yet finding the link title, if any.

  # $cur_child is advanced through the tree while we parse the link destination
  # and title, it always point to the node that we are currently looking into
  # (the one containing the end of the element that was previously found).
  # $n is the node at index $cur_child.
  my $cur_child = $child_start;
  my $n = $tree->{children}[$cur_child];
  die 'Unexpected link destination search in a non-text element: '.$n->{type}
      unless $n->{type} eq 'text';
  my @start = ($child_start, $text_start, $child_start, $text_start + 1);
  # TODO: use find_in_text bounded (to work across child limit) (maybe not
  # really needed as this should never be a different child).
  my $collapsed;
  if (substr($n->{content}, $text_start, 1) eq '(') {
    my @target = parse_inline_link($tree, @start);
    return @target if @target;
  } elsif (substr($n->{content}, $text_start, 2) eq '[]') {
    # https://spec.commonmark.org/0.31.2/#collapsed-reference-link
    $collapsed = 2;
    # passthrough intended.
  } elsif (substr($n->{content}, $text_start, 1) eq '[') {
    my @target = parse_reference_link($that, $tree, @start);
    return @target if @target;
    return;
  } else {
    # https://spec.commonmark.org/0.31.2/#shortcut-reference-link
    $collapsed = 0;
    # passthrough intended.
  }

  # TODO: assert defined(collapsed).
  # We have a syntax that might be a shortcut reference link or a
  # collapsed reference link. We check if we have a matching label.
  my $ref = $tree->span_to_source_text(@text_span, UNESCAPE_LITERAL);
  $ref = normalize_label($ref) if $ref;
  if (exists $that->{linkrefs}{$ref}) {
    $tree->extract($child_start, $text_start, $child_start, $text_start + $collapsed) if $collapsed;
    return %{$that->{linkrefs}{$ref}};
  }
  return;
}

sub parse_inline_link {
  my ($tree, @start) = @_;  # ($child_start, $text_start, $child_start, $text_start + 1);
  # @start points to before and after the '(' character opening the link.

  my $cur_child = $start[0];
  my $n = $tree->{children}[$cur_child];

  pos($n->{content}) = $start[3];
  $n->{content} =~ m/\G[ \t]*\n?[ \t]*/;
  my $search_start = $LAST_MATCH_END[0];
  
  # TODO: first check if we have a destination between <>, that may have already
  # been matched as an autolink or as a closing HTML tag :-(

  my @target;
  my $ok_to_have_title = 1;

  my $has_bracket = $tree->find_in_text(qr/</, $cur_child, $search_start, $cur_child, $search_start + 1);

  # We have this variable early because we may be filling it soon if the link
  # destination was already parsed as an autolink or an html element.
  my $target = '';

  if ($has_bracket) {
    if (my @end_target = $tree->find_in_text(qr/>/, $cur_child, $search_start + 1)) {
      @target = ($cur_child, $search_start + 1, $end_target[0], $end_target[1]);
      return if $tree->find_in_text(qr/<|\n/, @target);
    }
  } elsif (length($n->{content}) <= $search_start && @{$tree->{children}} > $cur_child && 
           ($tree->{children}[$cur_child + 1]{type} eq 'html' || $tree->{children}[$cur_child + 1]{type} eq 'link')) {
    # The element inside was already parsed as an autolink or an html element,
    # we use it as-is for the link destination.
    @target = ($cur_child + 1, 0, $cur_child + 2, 0);
    my $link_node = $tree->{children}[$cur_child + 1];
    if ($link_node->{type} eq 'html') {
      $target = $link_node->{content};
      $target =~ s/^<|>$//g;
    } else {
      $target = $link_node->{target};
    }
    return if $target =~ m/\n/;  # No new lines in link targets are allowed.
  } elsif (my @end_target = $tree->find_in_text_with_balanced_content(qr/\(/, qr/\)/, qr/[ [:cntrl:]]/, $cur_child, $search_start)) {
    @target = ($cur_child, $search_start, $end_target[0], $end_target[1]);
  }
  if (@target) {
    # We can’t extract the target just yet, because the parsing can still fail
    # in which case we must not modify the tree.
    $cur_child = $target[2];
    $n = $tree->{children}[$cur_child];
    # On the next line, [1] and not [2] because if there was a control character 
    # we will fail the whole method. So we restart the search before the end
    # condition of the find... method above.
    pos($n->{content}) = $target[3] + ($has_bracket ? 1 : 0);
    $n->{content} =~ m/\G[ \t]*\n?[ \t]*/;
    $search_start = $LAST_MATCH_END[0];
    $ok_to_have_title = $LAST_MATCH_END[0] != $LAST_MATCH_START[0];  # target and title must be separated.
  }

  # The first character of the title must be ", ', or ( and so can’t be another
  # inline construct. As such, using a normal regex is fine (and not an
  # InlineTree method).
  pos($n->{content}) = $search_start;
  my @end_title;
  if ($n->{content} =~ m/\G"/gc) {
    @end_title = $tree->find_in_text(qr/"/, $cur_child, $search_start + 1);
  } elsif ($n->{content} =~ m/\G'/gc) {
    @end_title = $tree->find_in_text(qr/'/, $cur_child, $search_start + 1);
  } elsif ($n->{content} =~ m/\G\(/gc) {
    @end_title = $tree->find_balanced_in_text(qr/\(/, qr/\)/, $cur_child, $search_start + 1);
  }
  my @title;
  if (@end_title) {
    return unless $ok_to_have_title;
    @title = ($cur_child, $search_start + 1, $end_title[0], $end_title[1]);
    $cur_child = $end_title[0];
    $n = $tree->{children}[$cur_child];
    pos($n->{content}) = $end_title[2];  # This time, we look after the closing character.
    $n->{content} =~ m/\G[ \t]*\n?[ \t]*/;
    $search_start = $LAST_MATCH_END[0];
  }

  # TODO: call a new InlineTree method to turn (child, offset_at_end) into
  # (child + 1, 0). This needs to be called also at the beginning of this
  # method.
  pos($n->{content}) = $search_start;
  return unless $n->{content} =~ m/\G\)/;

  # Now we have a valid title, we can start to rewrite the tree (beginning from
  # the end, to not alter the node index before we touch them).
  {
    my @last_item = (@title, @target, @start);
    # We remove the spaces after the last item and also the closing paren.
    $tree->extract($last_item[2], $last_item[3], $cur_child, $search_start + 1);
  }

  my $title;
  if (@title) {
    my $title_tree = $tree->extract(@title);
    $title = $title_tree->to_source_text();
    my @last_item = (@target, @start);
    $tree->extract($last_item[2], $last_item[3], $title[0], $title[1]);
  }

  if (@target) {
    my $target_tree = $tree->extract(@target);
    $target = $target_tree->to_source_text() unless $target;
    $tree->extract($start[2], $start[3], $target[0], $target[1]);
  }

  $tree->extract(@start);

  return (target => $target, ( $title ? (title => $title) : ()));
}

sub parse_reference_link {
  my ($that, $tree, @start) = @_;  # ($child_start, $text_start, $child_start, $text_start + 1);

  my $cur_child = $start[0];
  my $n = $tree->{children}[$cur_child];

  my $ref_start = $start[3];

  if (my @end_ref = $tree->find_in_text(qr/]/, $cur_child, $start[3])) {
    my $ref = normalize_label($tree->span_to_source_text(@start[2,3], @end_ref[0,1], UNESCAPE_LITERAL));
    # TODO: normalize the ref
    if (exists $that->{linkrefs}{$ref}) {
      $tree->extract(@start[0,1], @end_ref[0,2]);
      return %{$that->{linkrefs}{$ref}};
    }
  }
  return;
}

# This methods adds "style", that is it parses the emphasis (* and _) and also
# strike-through (~). To do so, we process each level of the tree independently
# because a style-run can’t cross another HTML construct (but it can span over
# it).
#
# We first find all the possible delimiters and insert them in the tree instead
# of their text. And then decide whether they are actually opening, closing, or
# neither.
#
# This methods implement all of:
# https://spec.commonmark.org/0.30/#emphasis-and-strong-emphasis
sub process_styles {
  my ($that, $tree) = @_;

  # We recurse first as there are less children to iterate over than after.
  for my $c (@{$tree->{children}}) {
    process_styles($that, $c->{subtree}) if exists $c->{subtree};
  }

  # TODO: only search for characters that are actually used by our current
  # options.
  my $current_child = 0;
  my @delimiters;
  while (my @match = $tree->find_in_text(qr/([*_~])\1*/, $current_child, 0)) {
    # We extract the delimiter run into a new node, that will be at $index.
    my ($delim_tree, $index) = $tree->extract($match[0], $match[1], $match[0], $match[2]);
    # We use the type literal so that if we do nothing with the delimiter it
    # will be rendered correctly. We keep track of which literals might be
    # delimiters using the @delimiters array.
    $delim_tree->{children}[0]{type} = 'literal';
    $tree->insert($index, $delim_tree);
    push @delimiters, classify_delimiter($that, $tree, $index, 'left');
    $current_child = $index + 1;
  }

  match_delimiters($that, $tree, @delimiters);
  return;
}

# Decides whether the delimiter run at the given index in the tree can open or
# close emphasis (or any other style).
sub classify_delimiter {
  my ($that, $tree, $index) = @_;
  my $pred_type = classify_flank($that, $tree, $index, 'left');
  my $succ_type = classify_flank($that, $tree, $index, 'right');
  my $is_left = $succ_type ne 'space' && ($succ_type ne 'punct' || $pred_type ne 'none');
  my $is_right = $pred_type ne 'space' && ($pred_type ne 'punct' || $succ_type ne 'none');
  my $len = length($tree->{children}[$index]{content});
  my $delim = substr $tree->{children}[$index]{content}, 0, 1;
  my $can_open = 0;
  my $can_close = 0;
  # This is implementing the first 8 rules (out of 17...) of
  # https://spec.commonmark.org/0.31.2/#emphasis-and-strong-emphasis
  # The rules are more complex for '_' than for '*' because it is assuming that
  # underscores can appear within word. So we apply the star rules to all other
  # delimiters (that is, we only check for underscore here). Currently our only
  # other delimiter is '~'.
  # TODO: add an option to decide which rule to apply per delimiter.
  if ($delim eq '_') {
    $can_open = $is_left && (!$is_right || $pred_type eq 'punct');
    $can_close = $is_right && (!$is_left || $succ_type eq 'punct');
  } else {
    $can_open = $is_left;
    $can_close = $is_right;
  }
  return {
    index => $index,
    can_open => $can_open,
    can_close => $can_close,
    len => $len,
    delim => $delim,
    orig_len => $len
  };
}

# Computes whether the type of the "flank" of the delimiter run at the given
# index in the tree (looking either at the "left" or "right" side). This returns
# one of 'none', 'punct', or 'space' following the rule given in
# https://spec.commonmark.org/0.31.2/#emphasis-and-strong-emphasis.
# The purpose is to decide whether the delimiter run is left flanking and/or
# right flanking (that decision happens in classify_delimiter).
sub classify_flank {
  my ($that, $tree, $index, $side) = @_;
  return 'space' if $index == 0 && $side eq 'left';
  return 'space' if $index == $#{$tree->{children}} && $side eq 'right';
  my $node = $tree->{children}[$index + ($side eq 'left' ? -1 : 1)];
  # If the node before the delimiters is not text, let’s assume that we had some
  # punctuation characters that delimited it.
  return 'punct' if $node->{type} ne 'text' && $node->{type} ne 'literal';
  my $space_re = $side eq 'left' ? qr/\s$/u : qr/^\s/u;
  return 'space' if $node->{content} =~ m/${space_re}/;
  my $punct_re = $side eq 'left' ? qr/[\p{Punct}\p{Symbol}]$/u : qr/^[\p{Punct}\p{Symbol}]/u;
  return 'punct' if $node->{content} =~ m/${punct_re}/;
  return 'none';
}

# We match the pair of delimiters together as much as we can, following the
# rules of the CommonMark spec.
sub match_delimiters {
  my ($that, $tree, @delimiters) = @_;

  for (my $close_index = 1; $close_index < @delimiters; $close_index++) {  ## no critic (ProhibitCStyleForLoops)
    my %c = %{$delimiters[$close_index]};
    next if !$c{can_close};
    # We have a closing delimiter, now we backtrack and find the tighter match
    # for this closing delimiter. This is because "*foo _bar* baz_" will only
    # match the * (that comes first) but "*foo *bar*"" will match the second
    # and third star, that are the tightest match. This is for rule 15 and 16 of
    # https://spec.commonmark.org/0.31.2/#emphasis-and-strong-emphasis
    # We also apply rules 9 and 10 here. Rules 1-8 have already been computed in
    # classify_delimiter.
    my $open_index =
        last_index { $_->{can_open} && $_->{delim} eq $c{delim} && valid_rules_9_10($_, \%c) }
    @delimiters[0 .. $close_index - 1];
    # TODO: here there are a lot of optimization that we could apply, based on
    # the "process emphasis" method from the spec (like removing our closing
    # delimiter if it is not an opener, and keeping track of the fact that
    # we have no delimiter in the 0..close_index-1 range that can match a
    # delimiter of the same type as %c).
    # This does not seem very important for reasonable inputs. So, instead, we
    # just check the next potential closer.
    next if $open_index == -1;

    $close_index = apply_delimiters($that, $tree, \@delimiters, $open_index, $close_index);
  }

  return;
}

# Given a tree, its delimiters and the index of two delimiters, rewrite the
# tree with the style applied by these delimiters (we’re assuming here that they
# are of a matching type).
#
# The delimiter may not be consumed entirely (but we will consume as much as
# possible).
sub apply_delimiters {
  my ($that, $tree, $delimiters, $open_index, $close_index) = @_;
  my %o = %{$delimiters->[$open_index]};
  my %c = %{$delimiters->[$close_index]};

  # We rewrite the tree in between our two delimiters.
  # TODO: maybe we need a splice method in InlineTree.
  my @styled_subnodes = splice @{$tree->{children}}, $o{index} + 1, $c{index} - $o{index} - 1;
  my $styled_tree = Markdown::Perl::InlineTree->new();
  $styled_tree->push(@styled_subnodes);
  # With our current algorithm in match_delimiters we know that there is no
  # reasons to recurse (because the closing delimiter here was the first
  # closing delimiter with a matching opener.)
  # my @styled_delimiters = map { $_->{index} -= $o{index} + 1; $_ } splice @{$delimiters},
  #    $open_index + 1, $close_index - $open_index - 1;
  # match_delimiters($that, $styled_tree, @styled_delimiters);
  splice @{$delimiters}, $open_index + 1, $close_index - $open_index - 1;

  # And now we rebuild our own tree around the new one.
  my $len = min($o{len}, $c{len}, 2);
  my $styled_node = new_style($styled_tree, tag => delim_to_html_tag($that, $o{delim} x $len));
  my $style_start = $o{index};
  my $style_length = 2;
  $close_index = $open_index + 1;
  if ($len < $o{len}) {
    substr($tree->{children}[$o{index}]{content}, $o{len} - $len) = '';  ## no critic (ProhibitLvalueSubstr)
    $delimiters->[$open_index]{len} -= $len;
    $style_start++;
    $style_length--;
  } else {
    splice @{$delimiters}, $open_index, 1;
    $close_index--;
  }
  if ($len < $c{len}) {
    # The closing node is now just after the opening one.
    substr($tree->{children}[$o{index} + 1]{content}, $c{len} - $len) = '';  ## no critic (ProhibitLvalueSubstr)
    $delimiters->[$close_index]{len} -= $len;
    $style_length--;
  } else {
    splice @{$delimiters}, $close_index, 1;  # We remove our closing delimiter.
  }
  splice @{$tree->{children}}, $style_start, $style_length, $styled_node;
  for my $i ($close_index .. $#{$delimiters}) {
    $delimiters->[$i]{index} -= $c{index} - $o{index} - 2 + $style_length;
  }
  return $open_index - ($len < $o{len} ? 0 : 1);
}

# Returns true if the given delimiters can be an open/close pair without
# breaking rules 9 and 10 of
# https://spec.commonmark.org/0.31.2/#emphasis-and-strong-emphasis.
sub valid_rules_9_10 {
  my ($o, $c) = @_;
  # TODO: BUG: there is a probable bug here in that the length of the delimiter
  # to consider is not its current length but the length of the original span
  # of which it was a part.
  return
         (!$o->{can_close} && !$c->{can_open})
      || (($o->{orig_len} + $c->{orig_len}) % 3 != 0)
      || ($o->{orig_len} % 3 == 0 && $c->{orig_len} % 3 == 0);
}

my %delimiters_map = (
  '*' => 'em',
  '**' => 'strong',
  '_' => 'em',
  '__' => 'strong',
  '~' => 's',
  '~~' => 'del',
  # TODO: use ^ and ˇ to represent sup and sub
  # TODO: add support for MathML in some way.
);

sub delim_to_html_tag {
  my ($that, $delim) = @_;
  # TODO: this must be based on options on $that.
  # TODO: this must be called somewhere in process_styles, to ensure that we
  # are building valid delimiters.
  # TODO: sort what to do if a given delimiter does not have a variant with
  # two characters (we must backtrack somewhere in match_delimiters probably).
  return $delimiters_map{$delim};
}

1;
