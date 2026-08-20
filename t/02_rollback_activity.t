#!perl

## Test the "rollback_activity" action

use 5.10.0;
use strict;
use warnings;
use Fcntl qw/:flock/;
use File::Spec::Functions qw/catfile/;
use File::Temp qw/tempdir/;
use Test::More;
use Time::HiRes qw/sleep/;
use lib 't','.';
use CP_Testing;

my $cp = CP_Testing->new({default_action => 'rollback_activity'});
my $dbh = $cp->test_database_handle();
my $state_dir = tempdir('check_postgresql.XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $state_file = catfile($state_dir, 'rollback_activity.state');

sub generate_activity {
    my ($rollbacks, $commits) = @_;
    my $activity_dbh = $cp->test_database_handle({quickreturn => 1});
    $activity_dbh->do('CREATE TEMP TABLE rollback_activity_test (id integer)');
    $activity_dbh->commit();

    for (1..$rollbacks) {
        $activity_dbh->do('INSERT INTO rollback_activity_test VALUES (1)');
        $activity_dbh->rollback();
    }
    for (1..$commits) {
        $activity_dbh->do('INSERT INTO rollback_activity_test VALUES (1)');
        $activity_dbh->commit();
    }

    $activity_dbh->disconnect();
    sleep 1.1;
    return;
}

sub read_state_file {
    my $filename = shift;
    open my $state_fh, '<', $filename
        or die qq{Could not read state fixture "$filename": $!\n};
    local $/;
    my $contents = <$state_fh>;
    close $state_fh or die qq{Could not close state fixture "$filename": $!\n};
    return $contents;
}

sub write_state_file {
    my ($filename, $contents) = @_;
    open my $state_fh, '>', $filename
        or die qq{Could not write state fixture "$filename": $!\n};
    print {$state_fh} $contents;
    close $state_fh or die qq{Could not close state fixture "$filename": $!\n};
    return;
}

my $result = $cp->run(qq{--state-file="$state_file"});

like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY OK:.*initial baseline}i,
    q{Action 'rollback_activity' records an initial baseline without alarming}
);
ok(-s $state_file, q{Action 'rollback_activity' writes its state file});
like(
    read_state_file($state_file),
    qr{\Acheck_postgresql rollback_activity state 1\n.*\nend\t\d+\n\z}s,
    q{Action 'rollback_activity' uses a versioned primitive state format}
);

$dbh->disconnect();
generate_activity(5, 1);

$result = $cp->run(
    qq{--state-file="$state_file" --warning=1% --critical=2% }
    . q{--min-xact-rate=0 --min-rollback-rate=0}
);

like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY CRITICAL:.*postgres.*rollback.*\|.*postgres_commit_rate=.*postgres_rollback_rate=.*postgres_xact_rate=.*postgres_rollback_ratio=}i,
    q{Action 'rollback_activity' alerts when recent ratio and rate gates are crossed}
);
unlike(
    $result,
    qr{_(?:commit|rollback|xact)_rate=[^ ]+[A-Za-z]},
    q{Action 'rollback_activity' emits portable unitless per-second rate perfdata}
);

my $warning_state_file = catfile($state_dir, 'warning.state');
$cp->run(qq{--state-file="$warning_state_file"});
generate_activity(5, 1);
$result = $cp->run(
    qq{--state-file="$warning_state_file" --warning=1% --critical=100% }
    . q{--min-xact-rate=0 --min-rollback-rate=0}
);
like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY WARNING:.*postgres.*rollback}i,
    q{Action 'rollback_activity' reports warning activity below the critical threshold}
);

my $gated_state_file = catfile($state_dir, 'gated.state');
$cp->run(qq{--state-file="$gated_state_file"});
generate_activity(5, 1);
$result = $cp->run(
    qq{--state-file="$gated_state_file" --warning=1% --critical=2% }
    . q{--min-xact-rate=100000 --min-rollback-rate=100000}
);
like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY OK:.*postgres.*rollback.*\|.*postgres_rollback_ratio=}i,
    q{Action 'rollback_activity' requires the ratio and both rate gates to cross}
);

my $filtered_state_file = catfile($state_dir, 'filtered.state');
$cp->run(qq{--state-file="$filtered_state_file"});
generate_activity(5, 1);
$result = $cp->run(
    qq{--state-file="$filtered_state_file" --warning=1% --critical=2% }
    . q{--min-xact-rate=0 --min-rollback-rate=0 --exclude=postgres}
);
like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY OK:}i,
    q{Action 'rollback_activity' honors database filters}
);
unlike(
    $result,
    qr{postgres_rollback_ratio=},
    q{Action 'rollback_activity' omits filtered databases from performance data}
);

my $multiple_target_state_file = catfile($state_dir, 'multiple_targets.state');
$cp->run('rollback_activityDB2', qq{--state-file="$multiple_target_state_file"});
sleep 0.2;
$result = $cp->run('rollback_activityDB2', qq{--state-file="$multiple_target_state_file"});
like(
    $result,
    qr{target1_postgres_rollback_ratio=},
    q{Action 'rollback_activity' qualifies the first target's duplicate database perfdata}
);
like(
    $result,
    qr{target2_postgres_rollback_ratio=},
    q{Action 'rollback_activity' qualifies the second target's duplicate database perfdata}
);

my $new_database_state_file = catfile($state_dir, 'new_database.state');
$cp->run(qq{--state-file="$new_database_state_file"});
my $admin_dbh = $cp->test_database_handle({quickreturn => 1});
$admin_dbh->commit();
$admin_dbh->{AutoCommit} = 1;
$admin_dbh->do('CREATE DATABASE rollback_activity_new');
$admin_dbh->disconnect();
sleep 1.1;
$result = $cp->run(
    qq{--state-file="$new_database_state_file" --critical=0% }
    . q{--min-xact-rate=0 --min-rollback-rate=0}
);
like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY OK:}i,
    q{Action 'rollback_activity' baselines a newly observed database without alerting}
);
unlike(
    $result,
    qr{rollback_activity_new_rollback_ratio=},
    q{Action 'rollback_activity' does not emit perfdata before a new database has a prior sample}
);
sleep 0.2;
$result = $cp->run(qq{--state-file="$new_database_state_file"});
like(
    $result,
    qr{rollback_activity_new_rollback_ratio=},
    q{Action 'rollback_activity' evaluates a new database after recording its baseline}
);
$admin_dbh = $cp->test_database_handle({quickreturn => 1});
$admin_dbh->commit();
$admin_dbh->{AutoCommit} = 1;
$admin_dbh->do('DROP DATABASE rollback_activity_new');
$admin_dbh->do('CREATE DATABASE rollback_activity_new');
$admin_dbh->disconnect();
sleep 1.1;
$result = $cp->run(
    qq{--state-file="$new_database_state_file" --critical=0% }
    . q{--min-xact-rate=0 --min-rollback-rate=0}
);
like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY OK:}i,
    q{Action 'rollback_activity' refreshes the baseline when a database is recreated}
);
unlike(
    $result,
    qr{rollback_activity_new_rollback_ratio=},
    q{Action 'rollback_activity' does not compare a recreated database with its predecessor}
);
$admin_dbh = $cp->test_database_handle({quickreturn => 1});
$admin_dbh->commit();
$admin_dbh->{AutoCommit} = 1;
$admin_dbh->do('DROP DATABASE rollback_activity_new');
$admin_dbh->disconnect();

my $reset_state_file = catfile($state_dir, 'reset.state');
$cp->run(qq{--state-file="$reset_state_file"});
my $reset_dbh = $cp->test_database_handle({quickreturn => 1});
$reset_dbh->do('SELECT pg_stat_reset()');
$reset_dbh->commit();
$reset_dbh->disconnect();
sleep 1.1;
$result = $cp->run(
    qq{--state-file="$reset_state_file" --warning=1% --critical=2% }
    . q{--min-xact-rate=0 --min-rollback-rate=0}
);
like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY OK:}i,
    q{Action 'rollback_activity' refreshes its baseline after PostgreSQL statistics reset}
);

my $decreasing_state_file = catfile($state_dir, 'decreasing.state');
$cp->run(qq{--state-file="$decreasing_state_file"});
my @state_line = split /\n/, read_state_file($decreasing_state_file), -1;
my $postgres_hex = unpack 'H*', 'postgres';
for my $line (@state_line) {
    my @field = split /\t/, $line, -1;
    next if @field != 8 or $field[2] ne $postgres_hex;
    $field[5] += 1_000_000;
    $field[6] += 1_000_000;
    $line = join "\t", @field;
}
write_state_file($decreasing_state_file, join "\n", @state_line);
$result = $cp->run(
    qq{--state-file="$decreasing_state_file" --critical=0% }
    . q{--min-xact-rate=0 --min-rollback-rate=0}
);
like(
    $result,
    qr{^POSTGRES_ROLLBACK_ACTIVITY OK:}i,
    q{Action 'rollback_activity' refreshes its baseline after transaction counters decrease}
);
unlike(
    $result,
    qr{postgres_rollback_ratio=},
    q{Action 'rollback_activity' does not evaluate negative counter deltas}
);

my $corrupt_state_file = catfile($state_dir, 'corrupt.state');
open my $corrupt_fh, '>', $corrupt_state_file
    or die qq{Could not create corrupt state fixture: $!\n};
print {$corrupt_fh} "not a rollback_activity state file\n";
close $corrupt_fh or die qq{Could not close corrupt state fixture: $!\n};
$result = $cp->run(qq{--state-file="$corrupt_state_file"});
like(
    $result,
    qr{^ERROR:.*state file}i,
    q{Action 'rollback_activity' reports corrupt state as UNKNOWN}
);

my $truncated_state_file = catfile($state_dir, 'truncated.state');
$cp->run(qq{--state-file="$truncated_state_file"});
my $truncated_state = read_state_file($truncated_state_file);
$truncated_state =~ s/end\t\d+\n\z//;
write_state_file($truncated_state_file, $truncated_state);
$result = $cp->run(qq{--state-file="$truncated_state_file"});
like(
    $result,
    qr{^ERROR:.*state file}i,
    q{Action 'rollback_activity' rejects line-aligned truncated state}
);

my $preserved_state = read_state_file($state_file);
$result = $cp->run(
    qq{--state-file="$state_file" --dbhost="/no/such/postgresql/socket"}
);
like(
    $result,
    qr{^ERROR:},
    q{Action 'rollback_activity' reports a PostgreSQL query failure}
);
is(
    read_state_file($state_file),
    $preserved_state,
    q{Action 'rollback_activity' preserves the last good state after a query failure}
);

open my $lock_fh, '>>', "$state_file.lock"
    or die qq{Could not create state lock fixture: $!\n};
flock $lock_fh, LOCK_EX | LOCK_NB
    or die qq{Could not lock state fixture: $!\n};
$result = $cp->run(qq{--state-file="$state_file"});
like(
    $result,
    qr{^ERROR:.*already running}i,
    q{Action 'rollback_activity' rejects concurrent use of one state file}
);
close $lock_fh or die qq{Could not close state lock fixture: $!\n};

$result = $cp->run(q{--state-file="/no/such/directory/state"});
like(
    $result,
    qr{^ERROR:.*state directory}i,
    q{Action 'rollback_activity' reports an unusable state directory as UNKNOWN}
);

$result = $cp->run(qq{--state-file="$state_file" --min-xact-rate=-1});
like(
    $result,
    qr{^ERROR:.*min-xact-rate cannot be negative}i,
    q{Action 'rollback_activity' rejects negative transaction rate gates}
);

$result = $cp->run(qq{--state-file="$state_file" --warning=60% --critical=50%});
like(
    $result,
    qr{^ERROR:.*warning percentage cannot exceed critical percentage}i,
    q{Action 'rollback_activity' rejects inverted percentage thresholds}
);

$result = $cp->run(qq{--state-file="$state_file" --critical=101%});
like(
    $result,
    qr{^ERROR:.*percentages cannot exceed 100%}i,
    q{Action 'rollback_activity' rejects percentages above 100}
);

$result = $cp->run('');
like(
    $result,
    qr{^ERROR:.*requires --state-file}i,
    q{Action 'rollback_activity' requires a local state file}
);

$result = $cp->run(q{--state-file=relative.state});
like(
    $result,
    qr{^ERROR:.*state-file must be an absolute path}i,
    q{Action 'rollback_activity' rejects ambiguous relative state paths}
);

done_testing();

exit;
