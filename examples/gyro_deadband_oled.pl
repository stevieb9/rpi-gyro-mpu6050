#!/usr/bin/env perl

# Like gyro_oled.pl, but the OLED is only repainted when a reading has actually
# moved. Each value is fed through an RPi::Gyro::MPU6050::Deadband filter
# (windowed smoothing + a +/- threshold), so plain sensor jitter no longer
# triggers a redraw - the panel updates only on real motion / a real temp
# change. Wiring is identical to gyro_oled.pl (MPU-6050 + SSD1306 on the one
# I2C bus).
#
# Usage: perl gyro_deadband_oled.pl

use warnings;
use strict;

use RPi::Gyro::MPU6050;
use RPi::OLED::SSD1306::128_64;

my $mpu  = RPi::Gyro::MPU6050->new;
my $oled = RPi::OLED::SSD1306::128_64->new(0x3C);

$oled->text_size(1);

# One deadband filter per field. Thresholds suit each field's units, and a
# 5-sample window smooths brief noise. Order matches the reads and the display
# below: gx gy gz  ax ay az  temp
my @filter = (
    $mpu->deadband(threshold => 1.0,  window => 5),   # gyro x  (deg/s)
    $mpu->deadband(threshold => 1.0,  window => 5),   # gyro y
    $mpu->deadband(threshold => 1.0,  window => 5),   # gyro z
    $mpu->deadband(threshold => 0.02, window => 5),   # accel x (g)
    $mpu->deadband(threshold => 0.02, window => 5),   # accel y
    $mpu->deadband(threshold => 0.02, window => 5),   # accel z
    $mpu->deadband(threshold => 0.3,  window => 5),   # temp    (C)
);

print "calibrating gyro - keep the sensor still...\n";

$mpu->calibrate_gyro;

my $running = 1;
$SIG{INT} = sub { $running = 0 };

print "displaying on the OLED (deadband-gated), Ctrl-C to quit\n";

while ($running){
    my @reading = ($mpu->gyro, $mpu->accel, $mpu->temp);   # 7 values

    # Feed each reading through its filter; note if any field actually moved
    my $moved = 0;
    for my $i (0 .. $#filter){
        $filter[$i]->update($reading[$i]);
        $moved ||= $filter[$i]->changed;
    }

    # Repaint only when something changed - and show the settled values
    if ($moved){
        my @v = map { $_->value } @filter;

        my $screen = sprintf(
            "MPU-6050\n"
          . "Gx:%+7.1f\n"
          . "Gy:%+7.1f\n"
          . "Gz:%+7.1f dps\n"
          . "Ax:%+6.2f\n"
          . "Ay:%+6.2f\n"
          . "Az:%+6.2f g\n"
          . "Temp:%.1f C",
            @v,
        );

        $oled->clear_buffer;
        $oled->string($screen);
        $oled->display;
    }

    select(undef, undef, undef, 0.2);
}

# Blank the panel on the way out.
$oled->clear;

print "\nstopped\n";
