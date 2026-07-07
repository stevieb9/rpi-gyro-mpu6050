#!/usr/bin/env perl

# Stream live 6-axis motion data and die temperature to STDOUT.
#
# Usage: perl imu.pl

use warnings;
use strict;

use RPi::Gyro::MPU6050;

my $mpu = RPi::Gyro::MPU6050->new;

print "calibrating gyro - keep the sensor still...\n";

$mpu->calibrate_gyro;

my $running = 1;
$SIG{INT} = sub { $running = 0 };

print "streaming, Ctrl-C to quit\n";

while ($running){
    my ($ax, $ay, $az) = $mpu->accel;
    my ($gx, $gy, $gz) = $mpu->gyro;

    printf(
        "accel %+.2f %+.2f %+.2f g   gyro %+8.2f %+8.2f %+8.2f deg/s   %.1f C\n",
        $ax,
        $ay,
        $az,
        $gx,
        $gy,
        $gz,
        $mpu->temp,
    );

    select(undef, undef, undef, 0.2);
}
