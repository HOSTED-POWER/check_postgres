#!perl

## Test the check_postgresql executable

use 5.10.0;
use strict;
use warnings;
use Test::More tests => 4;

ok(-x 'check_postgresql', q{check_postgresql is executable});

my $result = qx{./check_postgresql --version 2>&1};
like(
    $result,
    qr{^check_postgresql version \d+\.\d+\.\d+-hp\d+}i,
    q{check_postgresql reports its own executable name}
);

$result = qx{./check_postgresql --help 2>&1};
like(
    $result,
    qr{rollback_activity\s+- Check recent rollback activity since the previous execution},
    q{check_postgresql help lists rollback_activity}
);

$result = qx{./check_postgresql --man 2>&1};
like(
    $result,
    qr{rollback_activity.*recent rollback activity}s,
    q{check_postgresql displays the main program manual}
);

exit;
