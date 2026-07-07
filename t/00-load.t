#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

# RPi::I2C is a compiled, Linux-only transport; satisfying its require
# up front lets the module load on any machine

BEGIN {
    $INC{'RPi/I2C.pm'} = __FILE__;

    use_ok( 'RPi::Gyro::MPU6050' ) || print "Bail out!\n";
}

diag( "Testing RPi::Gyro::MPU6050 $RPi::Gyro::MPU6050::VERSION, Perl $], $^X" );
