#!/usr/bin/env perl

# The simplest possible tour of RPi::Gyro::MPU6050::Deadband.
#
# A Deadband is just a "gate" for ONE number over time. You:
#
#   * show it each new reading with   $gate->update($n)
#   * ask whether it really moved with  $gate->changed
#   * read the current settled number with  $gate->value
#
# It has NO idea where the numbers come from - gyro, temperature, a bank
# balance, anything. It just gates whatever you feed it. So this example feeds
# it a hand-made list of numbers (no sensor at all) and prints what it decides
# for each one, so you can watch it work.
#
# Run it:  perl deadband_simple.pl

use warnings;
use strict;

use RPi::Gyro::MPU6050::Deadband;

# ---------------------------------------------------------------------------
# PART 1: the deadband (the "+/- threshold" part)
#
# threshold => 1.0  : ignore any move of 1.0 or less
# window    => 1    : no smoothing - judge each reading on its own
# ---------------------------------------------------------------------------

print "PART 1 - threshold 1.0, window 1 (no smoothing)\n\n";

my $gate = RPi::Gyro::MPU6050::Deadband->new(threshold => 1.0, window => 1);

# A made-up stream of readings. Watch which ones count as a "change".
my @readings = (10, 10.4, 9.8, 10.2, 13, 13.1, 12.8, 5);

printf "  %-6s  %-9s  %-6s\n", 'fed', 'changed?', 'value';
printf "  %-6s  %-9s  %-6s\n", '-----', '--------', '-----';

for my $n (@readings) {
    $gate->update($n);                      # show the gate the new number

    printf "  %-6s  %-9s  %-6g\n",
        $n,
        ($gate->changed ? 'YES' : '.'),     # did it move enough to matter?
        $gate->value;                       # the settled value to use
}

# ---------------------------------------------------------------------------
# PART 2: the window (the "average the last X checks" part)
#
# With window => 3 each reading is averaged over the last 3, so a single spike
# barely nudges the average and is ignored - only a SUSTAINED move crosses.
# ---------------------------------------------------------------------------

print "\nPART 2 - threshold 1.0, window 3 (averages the last 3)\n\n";

my $smooth = RPi::Gyro::MPU6050::Deadband->new(threshold => 1.0, window => 3);

# A steady 0, then one lone spike (ignored), then a sustained shift (counts).
my @spiky = (0, 0, 0, 3, 0, 0, 3, 3, 3);

printf "  %-6s  %-9s  %-6s\n", 'fed', 'changed?', 'value';
printf "  %-6s  %-9s  %-6s\n", '-----', '--------', '-----';

for my $n (@spiky) {
    $smooth->update($n);

    printf "  %-6s  %-9s  %-6g\n",
        $n,
        ($smooth->changed ? 'YES' : '.'),
        $smooth->value;
}

# ---------------------------------------------------------------------------
# That's the whole idea. To use it with the real sensor, the ONLY thing that
# ties a gate to a field is the line where you feed it, eg:
#
#   my $mpu = RPi::Gyro::MPU6050->new;
#   my $gx  = $mpu->deadband(threshold => 1.0, window => 5);
#   $gx->update( ($mpu->gyro)[0] );   # <-- THIS makes $gx "the gyro-X gate"
#
# The gate itself never knows it's gyro-X; you do.
# ---------------------------------------------------------------------------

print "\n";
