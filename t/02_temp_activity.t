#!perl

## Test the "temp_activity" action

use 5.10.0;
use strict;
use warnings;
use File::Spec::Functions qw/catfile/;
use File::Temp qw/tempdir/;
use Test::More;
use Time::HiRes qw/sleep/;
use lib 't','.';
use CP_Testing;

my $cp = CP_Testing->new({default_action => 'temp_activity'});
my $dbh = $cp->test_database_handle();
my $dir = tempdir('check_postgresql.XXXXXX', TMPDIR => 1, CLEANUP => 1);

sub state_file_in {
    my $d = shift;
    my ($f) = glob catfile($d, 'check_postgres.temp_activity.*');
    return $f;
}

## First run records a baseline and stays OK
my $result = $cp->run(qq{--audit-file-dir="$dir"});
like(
    $result,
    qr{^POSTGRES_TEMP_ACTIVITY OK:.*initial baseline}i,
    q{Action 'temp_activity' records an initial baseline without alarming}
);
ok(-s state_file_in($dir), q{Action 'temp_activity' writes its state file});

## Force a spill: a sort larger than work_mem writes temp files
$dbh->do('SET work_mem = "64kB"');
$dbh->do('SELECT count(*) FROM (SELECT generate_series(1,200000) ORDER BY 1 DESC) x');
$dbh->commit();
sleep 1.1;

## Second run evaluates a delta and emits the spill-rate perfdata
$result = $cp->run(qq{--audit-file-dir="$dir"});
like(
    $result,
    qr{^POSTGRES_TEMP_ACTIVITY (OK|WARNING|CRITICAL):.*\|.*_temp_mb_per_s=.*_temp_files_per_s=}i,
    q{Action 'temp_activity' emits spill-rate performance data on the second run}
);

## A very low critical rate must trip after a real spill
$dbh->do('SET work_mem = "64kB"');
$dbh->do('SELECT count(*) FROM (SELECT generate_series(1,200000) ORDER BY 1 DESC) x');
$dbh->commit();
sleep 1.1;
$result = $cp->run(qq{--audit-file-dir="$dir" --critical=0.0001});
like(
    $result,
    qr{^POSTGRES_TEMP_ACTIVITY CRITICAL:.*spilled}i,
    q{Action 'temp_activity' alerts when the spill rate exceeds critical}
);

## Non-numeric threshold is rejected
$result = $cp->run(qq{--audit-file-dir="$dir" --critical=abc});
like(
    $result,
    qr{^ERROR:.*MB/s}i,
    q{Action 'temp_activity' rejects a non-numeric threshold}
);

$dbh->disconnect();
done_testing();

exit;
