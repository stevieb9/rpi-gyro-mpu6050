#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'RPi::Gyro::MPU6050' ) || print "Bail out!\n";
}

diag( "Testing RPi::Gyro::MPU6050 $RPi::Gyro::MPU6050::VERSION, Perl $], $^X" );
