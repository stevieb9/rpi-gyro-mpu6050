#!/usr/bin/env perl

# Stream live 6-axis motion data and die temperature to an SSD1306 OLED,
# refreshing continuously until Ctrl-C. The MPU-6050 and the OLED share the
# one I2C bus (see the wiring notes below).
#
# Wiring - both devices hang off the same I2C bus:
#
#   pin            Pi
#   ------------   -----------------------------
#   VCC         -> 3V3    (pin 1 or 17)   * power the MPU from 3V3, NOT 5V
#   GND         -> GND    (pin 6, 9, ...)
#   SDA         -> GPIO2 / SDA1 (pin 3)
#   SCL         -> GPIO3 / SCL1 (pin 5)
#   AD0 (MPU)   -> GND    -> address 0x68 (tie to 3V3 for 0x69)
#
# The OLED uses its default address 0x3C. After wiring, `i2cdetect -y 1`
# should show both 0x68 (MPU-6050) and 0x3c (OLED).
#
# Usage: perl gyro_oled.pl

use warnings;
use strict;

use RPi::Gyro::MPU6050;
use RPi::OLED::SSD1306::128_64;

my $mpu  = RPi::Gyro::MPU6050->new;              # /dev/i2c-1, addr 0x68
my $oled = RPi::OLED::SSD1306::128_64->new(0x3C);

$oled->text_size(1);

print "calibrating gyro - keep the sensor still...\n";

$mpu->calibrate_gyro;

my $running = 1;
$SIG{INT} = sub { $running = 0 };

print "displaying on the OLED, Ctrl-C to quit\n";

while ($running){
    my ($ax, $ay, $az) = $mpu->accel;
    my ($gx, $gy, $gz) = $mpu->gyro;

    my $screen = sprintf(
        "MPU-6050\n"
      . "Gx:%+7.1f\n"
      . "Gy:%+7.1f\n"
      . "Gz:%+7.1f dps\n"
      . "Ax:%+6.2f\n"
      . "Ay:%+6.2f\n"
      . "Az:%+6.2f g\n"
      . "Temp:%.1f C",
        $gx,
        $gy,
        $gz,
        $ax,
        $ay,
        $az,
        $mpu->temp,
    );

    # Rebuild the whole frame in the buffer, then push it once - a single
    # write per frame, so the screen updates with no blank flash.
    $oled->clear_buffer;      # zero the buffer + home the cursor (no push)
    $oled->string($screen);   # draw the frame into the buffer
    $oled->display;           # push it to the panel

    select(undef, undef, undef, 0.2);
}

# Blank the panel on the way out.
$oled->clear;

print "\nstopped\n";
