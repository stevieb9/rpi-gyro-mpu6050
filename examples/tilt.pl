#!/usr/bin/env perl

# Stream pitch and roll angles derived from gravity. The low-pass
# filter is set to 21 Hz to quiet the readings for slow tilt work.
#
# Usage: perl tilt.pl

use warnings;
use strict;

use RPi::Gyro::MPU6050;

use constant {
    REG_CONFIG  => 0x1A,
    DLPF_21_HZ  => 0x04,
};

my $mpu = RPi::Gyro::MPU6050->new;

$mpu->register(REG_CONFIG, DLPF_21_HZ);

my $running = 1;
$SIG{INT} = sub { $running = 0 };

print "streaming, Ctrl-C to quit\n";

while ($running){
    my ($pitch, $roll) = $mpu->tilt;

    printf "pitch: %+6.1f  roll: %+6.1f\n", $pitch, $roll;

    select(undef, undef, undef, 0.2);
}
