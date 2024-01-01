use strict;
use warnings;
use utf8;

use FindBin;
use Test2::V0;

skip_all('Author test.  Set $ENV{TEST_AUTHOR} to a true value to run.') unless $ENV{TEST_AUTHOR};

skip_all('Python3 must be installed.') if system 'python3 -c "exit()" 2>/dev/null';

my $spec_dir = "${FindBin::Bin}/../third_party/cmark/test";
skip_all('cmark must be checked out.') unless -d $spec_dir;

my $root_dir = "${FindBin::Bin}/..";

my $test_suite_output = system "python3 ${spec_dir}/spec_tests.py --spec ${spec_dir}/spec.txt --track ${root_dir}/commonmark.tests --program '$^X -I${root_dir}/lib ${root_dir}/script/pmarkdown'";
is($test_suite_output, 0, 'Commonmark test suite');

done_testing;
