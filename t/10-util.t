use strict;
use warnings;
use utf8;

use Markdown::Perl::Util ':all';
use Test2::V0;

{
  my @a = (2, 4, 6, 7, 8, 9, 10);
  is([split_while { $_ % 2 == 0 } @a], [[2, 4, 6], [7, 8, 9, 10]], 'split_while1');
  is (\@a, [2, 4, 6, 7, 8, 9, 10], 'split_while2');
}

{
  my @a = (2, 4, 6);
  is([split_while { $_ % 2 == 0 } @a], [[2, 4, 6], []], 'split_while3');
}

is(remove_prefix_spaces(0, 'test'), 'test', 'remove_prefix_spaces1');
is(remove_prefix_spaces(0, '  test'), '  test', 'remove_prefix_spaces2');
is(remove_prefix_spaces(0, '    test'), '    test', 'remove_prefix_spaces3');
is(remove_prefix_spaces(2, '    test'), '  test', 'remove_prefix_spaces4');
is(remove_prefix_spaces(2, ' test'), 'test', 'remove_prefix_spaces5');
is(remove_prefix_spaces(2, 'test'), 'test', 'remove_prefix_spaces6');
is(remove_prefix_spaces(2, '    test'), '  test', 'remove_prefix_spaces7');
is(remove_prefix_spaces(2, "\ttest"), '  test', 'remove_prefix_spaces8');
is(remove_prefix_spaces(2, " \ttest"), "   test", 'remove_prefix_spaces9');
is(remove_prefix_spaces(2, "  \ttest"), "\ttest", 'remove_prefix_spaces10');
is(remove_prefix_spaces(4, '    test'), 'test', 'remove_prefix_spaces11');
is(remove_prefix_spaces(4, '      test'), '  test', 'remove_prefix_spaces12');
is(remove_prefix_spaces(8, '        test'), 'test', 'remove_prefix_spaces13');
is(remove_prefix_spaces(8, '          test'), '  test', 'remove_prefix_spaces14');
is(remove_prefix_spaces(2, "  \n"), "\n", 'remove_prefix_spaces15');

done_testing;