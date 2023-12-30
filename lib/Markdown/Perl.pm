package Markdown::Perl;

use strict;
use warnings;
use utf8;
use feature ':5.24';

use Exporter 'import';
use Hash::Util 'lock_keys';
use List::Util 'pairs';
use Markdown::Perl::Util 'split_while', 'remove_prefix_spaces', 'indented_one_tab', 'indent_size';
use Scalar::Util 'blessed';

our $VERSION = '0.01';

our @EXPORT = ();
our @EXPORT_OK = qw(convert);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

=pod

=encoding utf8

=cut

sub new {
  my ($class, %options) = @_;

  my $this = bless {
    options => \%options,
    local_options => {},
    blocks => [],
    blocks_stack => [],
    paragraph => [],
    lines => [] }, $class;
  lock_keys %{$this};

  return $this;
}

# Returns @_, unless the first argument is not blessed as a Markdown::Perl
# object, in which case it returns a default object.
my $default_this = Markdown::Perl->new();
sub _get_this_and_args {
  my $this = shift @_;
  # We could use `$this isa Markdown::Perl` that does not require to test
  # blessedness first. However this requires 5.31.6 which is not in Debian
  # stable as of writing this.
  unless (blessed($this) && $this->isa(__PACKAGE__)) {
    unshift @_, $this;
    $this = $default_this;
  }
  return ($this, @_);
}

# Takes a string and converts it to HTML. Can be called as a free function or as
# class method. In the latter case, provided options override those set in the
# class constructor.
# Both the input and output are unicode strings.
sub convert {
  my ($this, $md, %options) = &_get_this_and_args;
  $this->{local_options} = \%options;
  
  # https://spec.commonmark.org/0.30/#characters-and-lines
  my @lines = split(/(\n|\r|\r\n)/, $md);
  push @lines, '' if @lines % 2 != 0;  # Add a missing line ending.
  @lines = pairs @lines;
  # We simplify all blank lines (but keep the data around as it does matter in
  # some cases, so we move the black part to the line separator field).
  map { $_ = ['', $_->[0].$_->[1]] if $_->[0] =~ /^[ \t]+$/ } @lines;

  # https://spec.commonmark.org/0.30/#tabs
  # TODO: nothing to do at this stage.

  # https://spec.commonmark.org/0.30/#insecure-characters
  map { $_->[0] =~ s/\000/\xfffd/g } @lines;

  # https://spec.commonmark.org/0.30/#backslash-escapes
  # TODO: at a later stage, as escaped characters don’t have their Markdown
  # meaning, we need a way to represent that.
  # map { s{\\(.)}{slash_escape($1)}ge } @lines

  # https://spec.commonmark.org/0.30/#entity-and-numeric-character-references
  # TODO: probably nothing is needed here.


  # $this->{blocks} = [];
  # $this->{blocks_stack} = [];
  # $this->{paragraph} = [];
  $this->{lines} = \@lines;

  while (my $hd = shift @{$this->{lines}}) {
    $this->_parse_blocks($hd)
  }
  $this->_finalize_paragraph();
  while (@{$this->{blocks_stack}}) {
    $this->_restore_parent_block();
  }
  return $this->_emit_html(@{delete $this->{blocks}});
}

sub _finalize_paragraph {
  my ($this) = @_;
  return unless @{$this->{paragraph}};
  push @{$this->{blocks}}, { type => 'paragraph', content => $this->{paragraph}};
  $this->{paragraph} = [];
  return;
}

sub _add_block {
  my ($this, $block) = @_;
  $this->_finalize_paragraph();
  push @{$this->{blocks}}, $block;
  return;
}

sub _enter_child_block {
  my ($this, $hd, $new_block, $cond) = @_;
  $this->_finalize_paragraph();
  unshift @{$this->{lines}}, $hd;
  push @{$this->{blocks_stack}}, { cond => $cond, block => $new_block, parent_blocks => $this->{blocks} };
  $this->{blocks} = [];
  return;
}

sub _restore_parent_block {
  my ($this) = @_;
  # TODO: rename the variables here with something better.
  my $last_block = pop @{$this->{blocks_stack}};
  my $block = delete $last_block->{block};
  $block->{content} = $this->{blocks};
  $this->{blocks} = delete $last_block->{parent_blocks};
  $this->_add_block($block);
  return;
}

# Returns true if $l would be parsed as the continuation of a paragraph in the
# context of $this (which is not modified).
sub _test_lazy_continuation {
  my ($this, $l) = @_;
  return unless @{$this->{paragraph}};
  my $tester = new(ref($this), $this->{options}, $this->{local_options});
  $tester->{paragraph} = [@{$this->{paragraph}}];
  # We’re ignoring the eol of the original line as it should not affect parsing.
  $tester->_parse_blocks([$l, '']);
  return @{$tester->{paragraph}} > @{$this->{paragraph}};
}

my $thematic_break_re = qr/^ {0,3}(?:(?:-[ \t]*){3,}|(_[ \t]*){3,}|(\*[ \t]*){3,})$/;
my $block_quotes_re = qr/^ {0,3}>[ \t]?/;

# Parse at least one line of text to build a new block; and possibly several
# lines, depending on the block type.
# https://spec.commonmark.org/0.30/#blocks-and-inlines
sub _parse_blocks {
  my ($this, $hd) = @_;
  my $l = $hd->[0];

  {
    for my $i (0..$#{$this->{blocks_stack}}) {
      local *::_ = \$l;
      unless ($this->{blocks_stack}[$i]{cond}()) {
        $this->_finalize_paragraph();
        for my $j (@{$this->{blocks_stack}} > $i) {
          $this->_restore_parent_block();
        }
        last;
      }
    }
  }

  # https://spec.commonmark.org/0.30/#atx-headings
  if ($l =~ /^ {0,3}(#{1,6})(?:[ \t]+(.+?))??(?:[ \t]+#+)?[ \t]*$/) {
    # Note: heading breaks can interrupt a paragraph or a list
    # TODO: the content of the header needs to be interpreted for inline content.
    $this->_add_block({ type => 'heading', level => length($1), content => $2 // '', debug => 'atx' });
    return;
  }

  # https://spec.commonmark.org/0.30/#setext-headings
  if ($l =~ /^ {0,3}(-+|=+)[ \t]*$/ &&
     @{$this->{paragraph}} && indent_size($this->{paragraph}[0]) < 4) {
    # TODO: this should not interrupt a list if the heading is just one -
    my $c = substr $1, 0, 1;
    my $p = $this->{paragraph};
    my $m = $this->multi_lines_setext_headings;
    if ($m eq 'single_line' && @{$p} > 1) {
      my $last_line = pop @{$p};
      $this->_finalize_paragraph();
      $p = [$last_line];
    } elsif ($m eq 'break' && $l =~ m/${thematic_break_re}/) {
      $this->_finalize_paragraph();
      $this->_add_block({ type => 'break', debug => 'setext_as_break' });
      return;
    } elsif ($m eq 'ignore') {
      push @{$this->{paragraph}}, $l;
      return;
    }
    $this->{paragraph} = [];
    $this->_add_block({ type => 'heading', level => ($c eq '=' ? 1 : 2), content => $p, debug => 'setext' });
    return;
  }


  # https://spec.commonmark.org/0.30/#thematic-breaks
  # Thematic breaks are described first in the spec, but the setext headings has
  # precedence in case of conflict, so we test for the break after the heading.
  if ($l =~ /${thematic_break_re}/) {
    $this->_add_block({ type => 'break', debug => 'native_break' });
    return;
  }

  # https://spec.commonmark.org/0.30/#indented-code-blocks
  # Indented code blocks cannot interrupt a paragraph.
  if (!@{$this->{paragraph}} && indented_one_tab($l)) {
    my $last = -1;
    for my $i (0..$#{$this->{lines}}) {
      if (indented_one_tab($this->{lines}[$i]->[0])) {
        $last = $i;
      } elsif ($this->{lines}[$i]->[0] ne '') {
        last;
      }
    }
    my @code_lines = splice @{$this->{lines}}, 0, ($last + 1);
    my $code = join('', map { remove_prefix_spaces(4, $_->[0].$_->[1]) } ($hd, @code_lines));
    $this->_add_block({ type => "code", content => $code, debug => 'indented'});
    return;
  }

  # https://spec.commonmark.org/0.30/#fenced-code-blocks
  if ($l =~ /^(?<indent> {0,3})(?<fence>`{3,}|~{3,})[ \t]*(?<info>.*?)[ \t]*$/
            && (((my $f = substr $+{fence}, 0, 1) ne '`') || (index($+{info}, '`') == -1))) {
    my $l = length($+{fence});
    my $info = $+{info};
    my $indent = length($+{indent});
    my ($code_lines, $rest) = split_while { $_->[0] !~ m/^ {0,3}${f}{$l,}[ \t]*$/ } @{$this->{lines}};
    my $code = join('', map { remove_prefix_spaces($indent, $_->[0].$_->[1]) } @{$code_lines});
    # Note that @$rest might be empty if we never find the closing fence. The
    # spec says that we should then consider the whole doc to be a code block
    # although we could consider that this was then not a code-block.
    if (!$this->fenced_code_blocks_must_be_closed || @{$rest}) {
      shift @{$rest};  # OK even if @$rest is empty.
      $this->_add_block({ type => "code", content => $code, info => $info, debug => 'fenced' });
      $this->{lines} = $rest;
      return;
    } else {
      # pass-through intended
    }
  }

  # https://spec.commonmark.org/0.30/#block-quotes
  if ($l =~ /${block_quotes_re}/) {
    # TODO: handle laziness (block quotes where the > prefix is missing)
    my $cond = sub {
      return 1 if $_ =~ s/${block_quotes_re}//;
      return $this->_test_lazy_continuation($_);
    };
    $this->_enter_child_block($hd, { type => 'quotes' }, $cond);
    return;
  }

  # TODO:
  # - https://spec.commonmark.org/0.30/#html-blocks
  # - https://spec.commonmark.org/0.30/#link-reference-definitions

  # https://spec.commonmark.org/0.30/#paragraphs
  if ($l ne '') {
    push @{$this->{paragraph}}, $l;
    return;
  }


  # https://spec.commonmark.org/0.30/#blank-lines
  if ($l eq  '') {
    $this->_finalize_paragraph();
    return;
  } 
  
  {
    ...
  }
}

sub _emit_html {
  my ($this, @blocks) = @_;
  my $out =  '';
  for my $b (@blocks) {
    if ($b->{type} eq 'break') {
      $out .= "<hr />\n";
    } elsif ($b->{type} eq 'heading') {
      my $l = $b->{level};
      my $c = $b->{content};
      $c = join(' ',@{$c}) if ref $c eq 'ARRAY';
      $out .= "<h${l}>$c</h${l}>\n";
    } elsif ($b->{type} eq 'code') {
      my $c = $b->{content};
      my $i = '';
      if ($this->code_blocks_info eq 'language' && $b->{info}) {
        my $l = $b->{info} =~ s/\s.*//r;  # The spec does not really cover this behavior so we’re using Perl notion of whitespace here.
        $i = " class=\"language-${l}\"";
      }
      $out .= "<pre><code${i}>$c</code></pre>";
    } elsif ($b->{type} eq 'paragraph') {
      $out .= "<p>".join(' ', @{$b->{content}})."</p>\n";
    } elsif ($b->{type} eq 'quotes') {
      my $c = $this->_emit_html(@{$b->{content}});
      $out .= "<blockquote>\n${c}</blockquote>\n";
    }
  }
  return $out;
}

sub _get_option {
  my ($this, $option) = @_;
  return $this->{local_options}{$option} // $this->{options}{$option};
}

=pod

=head1 CONFIGURATION OPTIONS

=over 4

=item B<fenced_code_blocks_must_be_closed> I<default: false>

By default, a fenced code block with no closing fence will run until the end of
the document. With this setting, the openning fence will be treated as normal
text, rather than the start of a code block, if there is no matching closing
fence.

=cut

sub fenced_code_blocks_must_be_closed {
  my ($this) = @_;
  return $this->_get_option('fenced_code_blocks_must_be_closed') // 0;
}

=pod

=item B<code_blocks_info>

Fenced code blocks can have info strings on their opening lines (any text after
the C<```> or C<~~~> fence). This option controls what is done with that text.

The possible values are:

=over 4

=item B<ignored>

The info text is ignored.

=item B<language> I<(default)>

=back

=cut

sub code_blocks_info {
  my ($this) = @_;
  return $this->_get_option('code_blocks_info') // 'language';
}

=pod=item B<multi_lines_setext_headings>

The default behavior of setext headings in the CommonMark spec is that they can
have multiple lines of text preceeding them (forming the heading itself).

This option allows to change this behavior. And is illustrated with this example
of Markdown:

    Foo
    bar
    ---
    baz

The possible values are:

=over 4

=item B<single_line>

Only the last line of text is kept as part of the heading. The preceeding lines
are a paragraph of themselves. The result on the example would be:
paragraph C<Foo>, heading C<bar>, paragraph C<baz>

=item B<break>

If the heading underline can be interpreted as a thematic break, then it is
interpreted as such (normally the heading interpretation takes precedence). The
result on the example would be: paragraph C<Foo bar>, thematic break,
paragraph C<baz>.

If the heading underline cannot be interpreted as a thematic break, then the
heading will use the default B<multi_line> behavior.

=item B<multi_line> I<(default)>

This is the default CommonMark behavior where all the preceeding lines are part
of the heading. The result on the example would be:
heading C<Foo bar>, paragraph C<baz>

=item B<ignore>

The heading is ignored, and form just one large paragraph. The result on the
example would be: paragraph C<Foo bar --- baz>.

Note that this actually has an impact on the interpretation of the thematic
breaks too.

=back

=cut

sub multi_lines_setext_headings {
  my ($this) = @_;
  return $this->_get_option('multi_lines_setext_headings') // 'multi_line';
}

=pod

=back

=cut

1;
