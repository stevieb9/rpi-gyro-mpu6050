#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

# Swap the RPi::I2C transport for an in-memory register file, so the
# chip logic (scaling, ranges, calibration, power management) gets
# exercised with no hardware attached - and no RPi::I2C installed,
# which only builds on Linux

BEGIN {
    no warnings 'once';

    $INC{'RPi/I2C.pm'} = __FILE__;

    *RPi::I2C::new = sub {
        my (undef, @args) = @_;
        return MockI2C->new(@args);
    };
}

use RPi::Gyro::MPU6050;

plan tests => 36;

my $mpu = RPi::Gyro::MPU6050->new;

isa_ok $mpu, 'RPi::Gyro::MPU6050';

is MockI2C->peek(0x6B), 0x01, "new() wakes the chip onto the X gyro PLL clock";
is $mpu->accel_range, 2, "accel range reads back the power-on +/-2 g";
is $mpu->gyro_range, 250, "gyro range reads back the power-on +/-250 deg/s";

# +1 g, -1 g, +0.5 g at 16384 LSB/g

MockI2C->poke(0x3B, 0x40, 0x00, 0xC0, 0x00, 0x20, 0x00);

is_deeply
    [map { sprintf "%.4f", $_ } $mpu->accel],
    ['1.0000', '-1.0000', '0.5000'],
    "accel() scales raw counts to g";

is sprintf("%.4f", $mpu->accel('y')), '-1.0000', "accel() takes a single axis";

is $mpu->accel_range(8), 8, "accel_range(8) sets and returns the new range";
is MockI2C->peek(0x1C), 0x10, "...writing AFS_SEL 2 into ACCEL_CONFIG";
is sprintf("%.4f", $mpu->accel('x')), '4.0000',
    "...and the scaling follows (same counts, 4x the g)";

$mpu->register(0x1C, 0xE0);
$mpu->accel_range(4);

is MockI2C->peek(0x1C), 0xE8, "accel_range() preserves the self-test bits";

# +10 dps, -10 dps, 0 at 131 LSB/deg/s

MockI2C->poke(0x43, 0x05, 0x1E, 0xFA, 0xE2, 0x00, 0x00);

is_deeply
    [map { sprintf "%.4f", $_ } $mpu->gyro],
    ['10.0000', '-10.0000', '0.0000'],
    "gyro() scales raw counts to degrees/second";

is sprintf("%.4f", $mpu->gyro('x')), '10.0000', "gyro() takes a single axis";

is $mpu->gyro_range(500), 500, "gyro_range(500) sets and returns the new range";
is MockI2C->peek(0x1B), 0x08, "...writing FS_SEL 1 into GYRO_CONFIG";
is sprintf("%.4f", $mpu->gyro('x')), '20.0000',
    "...and the scaling follows (same counts, double the rate)";

$mpu->gyro_range(2000);
MockI2C->poke(0x43, 0x00, 0xA4);

is sprintf("%.4f", $mpu->gyro('x')), '10.0000',
    "the 2000 deg/s scale uses the published 16.4 LSB value, not a halving";

# (25 - 36.53) * 340 = -3920.2; -3920 is 0xF0B0

MockI2C->poke(0x41, 0xF0, 0xB0);

is sprintf("%.2f", $mpu->temp), '25.00', "temp() applies the datasheet formula";

$mpu->accel_range(2);

MockI2C->poke(0x3B, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00);

is_deeply
    [map { sprintf "%.1f", $_ } $mpu->tilt],
    ['0.0', '0.0'],
    "tilt() reads level when flat, component side up";

MockI2C->poke(0x3B, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00);

is_deeply
    [map { sprintf "%.1f", $_ } $mpu->tilt],
    ['90.0', '0.0'],
    "tilt() pitch reads +90 with the +X end straight up";

$mpu->gyro_range(250);
MockI2C->poke(0x43, 0x05, 0x1E, 0xFA, 0xE2, 0x00, 0x00);

my $offsets = $mpu->calibrate_gyro(4);

is_deeply
    [map { sprintf "%.4f", $offsets->{$_} } qw(x y z)],
    ['10.0000', '-10.0000', '0.0000'],
    "calibrate_gyro() measures the standing bias";

is_deeply
    [map { sprintf "%.4f", $_ } $mpu->gyro],
    ['0.0000', '0.0000', '0.0000'],
    "...and gyro() subtracts it";

$mpu->gyro_offsets({ x => 2.5 });

is_deeply
    [map { sprintf "%.4f", $mpu->gyro_offsets->{$_} } qw(x y z)],
    ['2.5000', '-10.0000', '0.0000'],
    "gyro_offsets() updates only the axes given";

my $copy = $mpu->gyro_offsets;
$copy->{x} = 99;

is $mpu->gyro_offsets->{x}, 2.5, "gyro_offsets() returns a copy, not the internals";

$mpu->sleep;

ok MockI2C->peek(0x6B) & 0x40, "sleep() sets the SLEEP bit";

$mpu->wake;

is MockI2C->peek(0x6B), 0x01, "wake() clears SLEEP and keeps the PLL clock select";

is $mpu->register(0x1A, 0x03), 3, "register() writes and returns the value";
is $mpu->register(0x1A), 3, "register() reads it back";

$mpu->accel_range(16);
$mpu->reset;

ok $MockI2C::device_reset_seen, "reset() writes the DEVICE_RESET bit";

# Note: the lexicals here aren't just tidiness. Once the line above
# has mentioned the MockI2C package, "is MockI2C->peek(...)" parses as
# the indirect method call MockI2C->is

my $pm1 = MockI2C->peek(0x6B);
is $pm1, 0x01, "...and re-initialises the chip awake on the PLL";
is $mpu->accel_range, 2, "...with the chip back at its power-on ranges";

my $custom = RPi::Gyro::MPU6050->new(
    accel_range  => 16,
    gyro_range   => 1000,
    gyro_offsets => { z => 1.5 },
);

my $accel_config = MockI2C->peek(0x1C);
my $gyro_config = MockI2C->peek(0x1B);

is $accel_config, 0x18, "new() applies the accel_range param";
is $gyro_config, 0x10, "new() applies the gyro_range param";
is $custom->gyro_offsets->{z}, 1.5, "new() applies the gyro_offsets param";

MockI2C->poke(0x75, 0x70);

my $ok = eval {
    RPi::Gyro::MPU6050->new;
    1;
};
is $ok, undef, "new() dies when the chip doesn't identify as an MPU-6050";
like $@, qr/no MPU-6050 found/, "...with a relevant error message";

$mpu->close;

eval { $mpu->temp; };
like $@, qr/device has been closed/, "methods croak once the device is closed";

# The in-memory chip: a shared register file, powered up with the
# MPU-6050's real defaults (asleep, WHO_AM_I answering 0x68). Writing
# the DEVICE_RESET bit reverts the file to that state, just as the
# silicon does

package MockI2C;

my %regs;
our $device_reset_seen = 0;

sub new {
    my ($class, $addr, $device) = @_;

    if (! %regs){
        _power_on();
    }

    return bless { addr => $addr, device => $device }, $class;
}
sub peek {
    my (undef, $reg) = @_;
    return defined $regs{$reg} ? $regs{$reg} : 0;
}
sub poke {
    my (undef, $reg, @bytes) = @_;
    my $i = 0;
    $regs{$reg + $i++} = $_ for @bytes;
}
sub read_block {
    my ($self, $num_bytes, $reg) = @_;
    return map { defined $regs{$reg + $_} ? $regs{$reg + $_} : 0 } 0 .. $num_bytes - 1;
}
sub read_byte {
    my ($self, $reg) = @_;
    return defined $regs{$reg} ? $regs{$reg} : 0;
}
sub write_byte {
    my ($self, $value, $reg) = @_;

    if ($reg == 0x6B && ($value & 0x80)){
        $device_reset_seen = 1;
        _power_on();
        return 0;
    }

    $regs{$reg} = $value;
    return 0;
}

sub _power_on {
    %regs = (0x6B => 0x40, 0x75 => 0x68);
}
