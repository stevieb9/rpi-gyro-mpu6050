#!perl
use strict;
use warnings;

use Test::More;

use RPi::Gyro::MPU6050::Deadband;

my $class = 'RPi::Gyro::MPU6050::Deadband';

# --- new(): parameter validation ---

eval { $class->new };
like $@, qr/threshold param/, "new() croaks without a threshold";

eval { $class->new(threshold => -1) };
like $@, qr/threshold param/, "new() croaks on a negative threshold";

eval { $class->new(threshold => 'x') };
like $@, qr/threshold param/, "new() croaks on a non-numeric threshold";

eval { $class->new(threshold => 1, window => 0) };
like $@, qr/window param/, "new() croaks on window 0";

eval { $class->new(threshold => 1, window => 2.5) };
like $@, qr/window param/, "new() croaks on a non-integer window";

# --- accessors + defaults ---

my $db = $class->new(threshold => 1.0);
isa_ok $db, $class;
is $db->threshold, 1.0, "threshold() returns the configured value";
is $db->window, 1, "window() defaults to 1";
is $db->value, undef, "value() is undef before the first update";
ok ! $db->changed, "changed() is false before the first update";

# --- first update establishes the baseline and always reports ---

is $db->update(5), 5, "update() returns the reported value";
ok $db->changed, "the first update() always reports a change";
is $db->value, 5, "value() is the first reading";

# --- within the band: no change reported, value held ---

$db->update(5.5);   # |5.5 - 5| = 0.5 <= 1.0
ok ! $db->changed, "a within-threshold move reports no change";
is $db->value, 5, "value() holds at the last reported value";

$db->update(6);     # |6 - 5| = 1.0 exactly: not > threshold, so no change
ok ! $db->changed, "a move of exactly the threshold is not a change (band inclusive)";
is $db->value, 5, "value() still held at the boundary";

# --- beyond the band: change reported, value advances ---

$db->update(6.5);   # |6.5 - 5| = 1.5 > 1.0
ok $db->changed, "a beyond-threshold move reports a change";
is $db->value, 6.5, "value() advances to the new reading";

# --- negatives ---

$db->update(-10);
ok $db->changed, "a large negative move reports a change";
is $db->value, -10, "value() handles negative readings";

# --- the window smooths a single spike away ---

my $w = $class->new(threshold => 1.0, window => 3);
$w->update(0);      # baseline 0
$w->update(0);
ok ! $w->changed, "steady stream: no change";
$w->update(3);      # window [0,0,3] -> mean 1.0, |1.0 - 0| = 1.0: no change
ok ! $w->changed, "a single spike inside the window is smoothed away";
$w->update(3);      # window [0,3,3] -> mean 2.0: crosses
ok $w->changed, "a sustained move eventually crosses the band";
cmp_ok abs($w->value - 2.0), '<', 1e-9, "the reported value is the smoothed mean";

# --- reset() ---

$db->reset;
is $db->value, undef, "reset() clears the reported value";
ok ! $db->changed, "reset() clears the changed flag";
$db->update(99);
ok $db->changed, "the first update after reset() reports again";

# --- update(): value validation ---

eval { $db->update('nope') };
like $@, qr/numeric value/, "update() croaks on a non-numeric value";

eval { $db->update() };
like $@, qr/numeric value/, "update() croaks on undef";

done_testing;
