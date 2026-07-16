package RPi::Gyro::MPU6050;

use strict;
use warnings;

use Carp qw(croak);
use RPi::I2C;
use RPi::Gyro::MPU6050::Deadband;

our $VERSION = '0.01';

use constant {
    DEFAULT_CAL_SAMPLES => 50,
    RESET_STAB          => 0.1,
    RAD_TO_DEG          => 45 / atan2(1, 1),    # 180 / pi
    REG_GYRO_CONFIG     => 0x1B,
    REG_ACCEL_CONFIG    => 0x1C,
    REG_ACCEL_OUT       => 0x3B,
    REG_TEMP_OUT        => 0x41,
    REG_GYRO_OUT        => 0x43,
    REG_PWR_MGMT_1      => 0x6B,
    REG_WHO_AM_I        => 0x75,
    WHO_AM_I_ID         => 0x68,
    PM1_DEVICE_RESET    => 0x80,
    PM1_SLEEP           => 0x40,
    PM1_CLKSEL_PLL_X    => 0x01,
    FS_SEL_MASK         => 0x18,
    FS_SEL_SHIFT        => 3,
    TEMP_LSB_PER_C      => 340,
    TEMP_OFFSET_C       => 36.53,
};

# Full-scale ranges map to the FS_SEL/AFS_SEL bit patterns; the LSB
# sensitivities are the datasheet's published values (note the gyro
# ones are not exact halvings)

my %accel_fs  = (2 => 0, 4 => 1, 8 => 2, 16 => 3);
my %accel_g   = reverse %accel_fs;
my %accel_lsb = (0 => 16384, 1 => 8192, 2 => 4096, 3 => 2048);

my %gyro_fs   = (250 => 0, 500 => 1, 1000 => 2, 2000 => 3);
my %gyro_dps  = reverse %gyro_fs;
my %gyro_lsb  = (0 => 131, 1 => 65.5, 2 => 32.8, 3 => 16.4);

# Public methods

sub new {
    my ($class, %args) = @_;

    my $self = bless {}, $class;

    if (defined $args{device} && ref $args{device}){
        croak "device param must be a string, eg. '/dev/i2c-1'";
    }

    $self->{device} = defined $args{device} ? $args{device} : '/dev/i2c-1';

    if (defined $args{addr} && ($args{addr} !~ /^\d+$/ || ($args{addr} != 0x68 && $args{addr} != 0x69))){
        croak "addr param must be 0x68 (AD0 low) or 0x69 (AD0 high)";
    }

    $self->{addr} = defined $args{addr} ? $args{addr} : 0x68;

    $self->{gyro_offsets}{$_} = 0 for qw(x y z);

    my $i2c = eval { RPi::I2C->new($self->{addr}, $self->{device}); };

    if (! defined $i2c){
        croak sprintf(
            "new() failed to open %s at addr 0x%02X: %s",
            $self->{device},
            $self->{addr},
            defined $@ && $@ ne '' ? $@ : 'unknown error',
        );
    }

    $self->{i2c} = $i2c;

    $self->_chip_init;

    if (defined $args{accel_range}){
        $self->accel_range($args{accel_range});
    }

    if (defined $args{gyro_range}){
        $self->gyro_range($args{gyro_range});
    }

    if (defined $args{gyro_offsets}){
        $self->gyro_offsets($args{gyro_offsets});
    }

    return $self;
}

sub accel {
    my ($self, $axis) = @_;

    if (defined $axis && $axis !~ /^[xyz]$/){
        croak "accel() \$axis param must be x, y or z";
    }

    my %g;
    @g{qw(x y z)} = map { $_ / $self->{accel_lsb} } $self->_read_axes(REG_ACCEL_OUT);

    return $g{$axis} if defined $axis;
    return @g{qw(x y z)};
}
sub accel_range {
    my ($self, $g) = @_;

    if (defined $g){
        if (! exists $accel_fs{$g}){
            croak "accel_range() \$g param must be one of 2, 4, 8 or 16";
        }

        my $config = ($self->_reg_read(REG_ACCEL_CONFIG) & ~FS_SEL_MASK) & 0xFF;

        $self->_reg_write(REG_ACCEL_CONFIG, $config | ($accel_fs{$g} << FS_SEL_SHIFT));
    }

    my $fs = ($self->_reg_read(REG_ACCEL_CONFIG) & FS_SEL_MASK) >> FS_SEL_SHIFT;

    $self->{accel_lsb} = $accel_lsb{$fs};

    return $accel_g{$fs};
}
sub calibrate_gyro {
    my ($self, $samples) = @_;

    if (defined $samples && ($samples !~ /^\d+$/ || $samples == 0)){
        croak "calibrate_gyro() \$samples param must be a positive integer";
    }

    $samples = DEFAULT_CAL_SAMPLES if ! defined $samples;

    # Raw reads rather than gyro(), so recalibrating doesn't stack on
    # top of the offsets already in place

    my %sum;

    for (1 .. $samples){
        my @dps = map { $_ / $self->{gyro_lsb} } $self->_read_axes(REG_GYRO_OUT);

        $sum{x} += $dps[0];
        $sum{y} += $dps[1];
        $sum{z} += $dps[2];
    }

    $self->{gyro_offsets}{$_} = $sum{$_} / $samples for qw(x y z);

    return $self->gyro_offsets;
}
sub close {
    my ($self) = @_;

    # Dropping the RPi::I2C object closes its file descriptor

    $self->{i2c} = undef;

    return 0;
}
sub deadband {
    my ($self, %args) = @_;

    # Convenience factory for a RPi::Gyro::MPU6050::Deadband filter, so callers
    # can build one straight off the sensor object. The filter is standalone
    # and reads no hardware - see RPi::Gyro::MPU6050::Deadband.
    return RPi::Gyro::MPU6050::Deadband->new(%args);
}
sub gyro {
    my ($self, $axis) = @_;

    if (defined $axis && $axis !~ /^[xyz]$/){
        croak "gyro() \$axis param must be x, y or z";
    }

    my %dps;
    @dps{qw(x y z)} = map { $_ / $self->{gyro_lsb} } $self->_read_axes(REG_GYRO_OUT);

    $dps{$_} -= $self->{gyro_offsets}{$_} for qw(x y z);

    return $dps{$axis} if defined $axis;
    return @dps{qw(x y z)};
}
sub gyro_offsets {
    my ($self, $offsets) = @_;

    if (defined $offsets){
        if (ref $offsets ne 'HASH'){
            croak "gyro_offsets() \$offsets param must be a hashref with " .
                  "x, y and/or z keys";
        }

        for my $axis (sort keys %{$offsets}){
            if ($axis !~ /^[xyz]$/){
                croak "gyro_offsets() axis keys must be x, y or z, not '$axis'";
            }

            if (! defined $offsets->{$axis} || $offsets->{$axis} !~ /^-?\d+(?:\.\d+)?$/){
                croak "gyro_offsets() $axis value must be a number of " .
                      "degrees/second";
            }

            $self->{gyro_offsets}{$axis} = $offsets->{$axis};
        }
    }

    # A copy, so the caller can't reach into our calibration

    return { %{$self->{gyro_offsets}} };
}
sub gyro_range {
    my ($self, $dps) = @_;

    if (defined $dps){
        if (! exists $gyro_fs{$dps}){
            croak "gyro_range() \$dps param must be one of 250, 500, 1000 or 2000";
        }

        my $config = ($self->_reg_read(REG_GYRO_CONFIG) & ~FS_SEL_MASK) & 0xFF;

        $self->_reg_write(REG_GYRO_CONFIG, $config | ($gyro_fs{$dps} << FS_SEL_SHIFT));
    }

    my $fs = ($self->_reg_read(REG_GYRO_CONFIG) & FS_SEL_MASK) >> FS_SEL_SHIFT;

    $self->{gyro_lsb} = $gyro_lsb{$fs};

    return $gyro_dps{$fs};
}
sub register {
    my ($self, $reg, $value) = @_;

    if (! defined $reg || $reg !~ /^\d+$/ || $reg > 255){
        croak "register() requires the \$reg param, an integer between 0-255";
    }

    if (defined $value){
        if ($value !~ /^\d+$/ || $value > 255){
            croak "register() \$value param must be an integer between 0-255";
        }
        $self->_reg_write($reg, $value);
        return $value;
    }

    return $self->_reg_read($reg);
}
sub reset {
    my ($self) = @_;

    $self->_reg_write(REG_PWR_MGMT_1, PM1_DEVICE_RESET);

    # DEVICE_RESET self-clears once the reset completes, and the chip
    # comes back asleep on power-on defaults; give it time, then
    # re-initialise exactly as new() does

    select(undef, undef, undef, RESET_STAB);

    $self->_chip_init;

    return 0;
}
sub sleep {
    my ($self) = @_;

    my $pm1 = $self->_reg_read(REG_PWR_MGMT_1);

    $self->_reg_write(REG_PWR_MGMT_1, ($pm1 | PM1_SLEEP) & 0xFF);

    return 0;
}
sub temp {
    my ($self) = @_;

    my @bytes = $self->_i2c->read_block(2, REG_TEMP_OUT);

    my $raw = $self->_s16(($bytes[0] << 8) | $bytes[1]);

    return $raw / TEMP_LSB_PER_C + TEMP_OFFSET_C;
}
sub tilt {
    my ($self) = @_;

    my ($gx, $gy, $gz) = $self->accel;

    my $pitch = atan2($gx, sqrt($gy * $gy + $gz * $gz)) * RAD_TO_DEG;
    my $roll  = atan2($gy, $gz) * RAD_TO_DEG;

    return ($pitch, $roll);
}
sub wake {
    my ($self) = @_;

    my $pm1 = $self->_reg_read(REG_PWR_MGMT_1);

    $self->_reg_write(REG_PWR_MGMT_1, ($pm1 & ~PM1_SLEEP) & 0xFF);

    return 0;
}

sub DESTROY {
    my ($self) = @_;
    $self->close;
}

# Private methods

sub _chip_init {
    my ($self) = @_;

    # The identity check doubles as a presence check; a missing chip
    # won't ACK, and the read comes back -1

    my $id = $self->_i2c->read_byte(REG_WHO_AM_I);

    if (! defined $id || $id != WHO_AM_I_ID){
        croak sprintf(
            "no MPU-6050 found at addr 0x%02X on %s (WHO_AM_I returned %s, expected 0x68)",
            $self->{addr},
            $self->{device},
            defined $id ? sprintf("0x%02X", $id & 0xFF) : 'undef',
        );
    }

    # The chip powers up asleep on its (less accurate) internal
    # oscillator; wake it onto the X gyro PLL, the datasheet's
    # recommended clock source

    $self->_reg_write(REG_PWR_MGMT_1, PM1_CLKSEL_PLL_X);

    # The range getters cache the LSB scale factors from whatever the
    # chip's config registers currently hold

    $self->accel_range;
    $self->gyro_range;

    return 0;
}
sub _i2c {
    my ($self) = @_;

    if (! defined $self->{i2c}){
        croak "the device has been closed";
    }

    return $self->{i2c};
}
sub _read_axes {
    my ($self, $reg) = @_;

    # One burst read; the chip freezes its user-facing registers while
    # the bus is active, so all three axes come from the same sampling
    # instant

    my @bytes = $self->_i2c->read_block(6, $reg);

    return map { $self->_s16(($bytes[$_ * 2] << 8) | $bytes[$_ * 2 + 1]) } 0 .. 2;
}
sub _reg_read {
    my ($self, $reg) = @_;

    my $value = $self->_i2c->read_byte($reg);

    if (! defined $value || $value == -1){
        croak sprintf("register 0x%02X read failed: %s", $reg, $!);
    }

    return $value;
}
sub _reg_write {
    my ($self, $reg, $value) = @_;

    my $rc = $self->_i2c->write_byte($value, $reg);

    if (defined $rc && $rc == -1){
        croak sprintf("register 0x%02X write failed: %s", $reg, $!);
    }

    return 0;
}
sub _s16 {
    my ($self, $value) = @_;
    return $value > 0x7FFF ? $value - 0x10000 : $value;
}

sub _vim{}; # Fold placeholder

1;
__END__

=head1 NAME

RPi::Gyro::MPU6050 - Interface to the InvenSense MPU-6050 6-axis
gyroscope/accelerometer over the I2C bus

=for html
<a href="https://github.com/stevieb9/rpi-gyro-mpu6050/actions"><img src="https://github.com/stevieb9/rpi-gyro-mpu6050/workflows/CI/badge.svg"/></a>
<a href='https://coveralls.io/github/stevieb9/rpi-gyro-mpu6050?branch=main'><img src='https://coveralls.io/repos/stevieb9/rpi-gyro-mpu6050/badge.svg?branch=main&service=github' alt='Coverage Status' /></a>


=head1 SYNOPSIS

    use RPi::Gyro::MPU6050;

    my $mpu = RPi::Gyro::MPU6050->new;

    # Acceleration in g, rotation rate in degrees/second

    my ($ax, $ay, $az) = $mpu->accel;
    my ($gx, $gy, $gz) = $mpu->gyro;

    # ...or a single axis of either

    my $az = $mpu->accel('z');
    my $gz = $mpu->gyro('z');

    # Die temperature, celsius

    my $c = $mpu->temp;

    # Tilt angles from gravity, in degrees

    my ($pitch, $roll) = $mpu->tilt;

    # Wider ranges trade resolution for headroom

    $mpu->accel_range(8);      # +/-8 g
    $mpu->gyro_range(1000);    # +/-1000 deg/s

    # One-time gyro bias calibration (sensor perfectly still)

    $mpu->calibrate_gyro;

    # Powering down

    $mpu->sleep;    # stop the sensors, ~10uA; registers and calibration kept
    $mpu->wake;     # resume sampling

=head1 DESCRIPTION

Interface to the InvenSense MPU-6050, the ubiquitous 6-axis motion
tracking chip (the part on the GY-521 breakout board). It combines a
3-axis gyroscope, a 3-axis accelerometer and a die temperature sensor,
each axis behind its own 16-bit ADC, with selectable full-scale ranges
on both motion sensors.

The gyroscope measures I<rotation rate> in degrees per second; the
accelerometer measures linear acceleration - including gravity, which
is what L</tilt> uses to derive static pitch and roll angles.

This distribution is pure Perl. The I2C transport is provided by
L<RPi::I2C>, which carries the compiled layer and talks to the chip
through the kernel's C</dev/i2c-N> interface.

The chip powers up asleep; C<new()> wakes it onto the X gyro PLL (the
datasheet's recommended clock source) and verifies the chip's identity
via its C<WHO_AM_I> register.

=head1 METHODS

=head2 new

Instantiates a new L<RPi::Gyro::MPU6050> object, opens the I2C bus,
verifies the chip responds, and wakes it up.

I<Parameters>:

All parameters are sent in within a single hash, and all are optional.

    device => $str

I<Optional, String>: The I2C bus device. Defaults to C</dev/i2c-1>.

    addr => $int

I<Optional, Integer>: The chip's 7-bit I2C address: C<0x68> with the
C<AD0> pin low (the default), C<0x69> with it high.

    accel_range => $int

I<Optional, Integer>: The accelerometer full-scale range in g; one of
C<2>, C<4>, C<8> or C<16>. If not supplied, the chip keeps its current
range (C<2> from power-on). See L</accel_range>.

    gyro_range => $int

I<Optional, Integer>: The gyroscope full-scale range in degrees/second;
one of C<250>, C<500>, C<1000> or C<2000>. If not supplied, the chip
keeps its current range (C<250> from power-on). See L</gyro_range>.

    gyro_offsets => $hashref

I<Optional, Hashref>: Per-axis gyro bias offsets in degrees/second,
with C<x>, C<y> and/or C<z> keys - typically the values a previous
L</calibrate_gyro> returned. Defaults to zero all around.

I<Returns>: The L<RPi::Gyro::MPU6050> object. Croaks if the bus can't
be opened, or the chip doesn't identify itself as an MPU-6050.

=head2 accel

Reads the accelerometer.

I<Parameters>:

    $axis

I<Optional, String>: C<x>, C<y> or C<z> to read a single axis.

I<Returns>: With C<$axis>, that axis' acceleration in g as a floating
point number. Without, a three element list of C<(x, y, z)>
acceleration in g. At rest, an axis pointing straight up reads C<+1>,
straight down C<-1>, and horizontal C<0>.

All three axes come from a single burst read, so they belong to the
same sampling instant. See L</DATA CONSISTENCY>.

=head2 gyro

Reads the gyroscope, minus the offsets set by L</calibrate_gyro> /
L</gyro_offsets>.

I<Parameters>:

    $axis

I<Optional, String>: C<x>, C<y> or C<z> to read a single axis.

I<Returns>: With C<$axis>, that axis' rotation rate in degrees per
second as a floating point number. Without, a three element list of
C<(x, y, z)> rates. Positive values follow the right-hand rule around
each positive axis, and a motionless (calibrated) sensor reads near
zero.

=head2 temp

Reads the on-die temperature sensor. It tracks the chip, not the room -
expect it to read a little above ambient.

Takes no parameters.

I<Returns>: The temperature in degrees celsius, per the datasheet
formula C<raw / 340 + 36.53>.

=head2 tilt

Derives the sensor's attitude from the static pull of gravity on the
accelerometer.

Meaningful only while the sensor is at rest - under acceleration,
gravity can't be told apart from the motion. (The gyroscope can't help
directly either; it reads rate, not angle.)

Takes no parameters.

I<Returns>: A two element list, C<($pitch, $roll)>, in degrees. Pitch
is positive when the C<+X> end tips up (+/-90); roll is positive when
the C<+Y> end tips up (+/-180). Both read C<0> when the board lies
flat, component side up.

=head2 accel_range

Sets and/or gets the accelerometer's full-scale range. Wider ranges
measure harder shocks; narrower ranges resolve finer detail. See
L</SCALING>.

I<Parameters>:

    $g

I<Optional, Integer>: The new range: C<2>, C<4>, C<8> or C<16>.

I<Returns>: The current range in g.

=head2 gyro_range

Sets and/or gets the gyroscope's full-scale range. C<250> deg/s
resolves the finest motion; C<2000> tracks the fastest spins. See
L</SCALING>.

I<Parameters>:

    $dps

I<Optional, Integer>: The new range: C<250>, C<500>, C<1000> or
C<2000>.

I<Returns>: The current range in degrees/second.

=head2 calibrate_gyro

Measures the gyro's standing bias. Every MEMS gyro reports a small
constant rotation while sitting perfectly still; this method averages a
burst of readings and stores the result as per-axis offsets, which
L</gyro> subtracts thereafter.

The sensor B<must> be motionless while this runs (orientation doesn't
matter). Bias drifts with temperature, so calibrate somewhere near
operating conditions, and persist the returned offsets to feed back
into C<new()>'s C<gyro_offsets> param on later runs.

I<Parameters>:

    $samples

I<Optional, Integer>: The number of reads to average. Defaults to
C<50>.

I<Returns>: The new per-axis offsets in degrees/second, as a hashref
with C<x>, C<y> and C<z> keys - the same form C<new()>'s
C<gyro_offsets> param and L</gyro_offsets> accept.

=head2 gyro_offsets

Sets and/or gets the per-axis gyro bias offsets.

I<Parameters>:

    $offsets

I<Optional, Hashref>: C<x>, C<y> and/or C<z> keys, each a rate in
degrees/second (negatives welcome). Axes not mentioned keep their
current value.

I<Returns>: A hashref of all three axes' offsets.

=head2 sleep

Puts the chip into low-power sleep - all sensing stops, and the sensor
registers hold their last values. Register contents survive.

Takes no parameters. I<Returns>: C<0> upon success.

=head2 wake

Wakes the chip from sleep.

Takes no parameters. I<Returns>: C<0> upon success.

=head2 reset

Resets the chip to its power-on defaults (asleep, +/-2 g, +/-250 deg/s,
everything else zeroed), then re-initialises it exactly as C<new()>
does. The software gyro offsets held by this object survive; ranges set
earlier do not.

Takes no parameters. I<Returns>: C<0> upon success.

=head2 register

Reads or writes any register on the chip directly, for the (many)
features this API doesn't wrap. See L</REGISTER MAP> and
L</BEYOND THIS API>.

I<Parameters>:

    $reg

I<Mandatory, Integer>: The register address, C<0>-C<255>.

    $value

I<Optional, Integer>: A byte to write, C<0>-C<255>. If omitted, the
register is read instead.

I<Returns>: The byte read, or the byte written.

=head2 close

Closes the I2C connection and invalidates the object. Called
automatically on C<DESTROY>. The chip keeps running - call L</sleep>
first if you want it powered down.

Takes no parameters. I<Returns>: C<0>.

=head2 deadband

Convenience factory that returns a new L<RPi::Gyro::MPU6050::Deadband> filter,
so you can build one straight off the sensor object without a separate C<use>.
The filter is a standalone, hardware-free helper that reports only once a noisy
reading has B<meaningfully> changed - handy for feeding C<gyro()> / C<accel()>
/ C<temp()> values through so a consumer (a display, a log, a network push) can
skip work while the sensor is essentially still. Compose one per axis.

Takes the same parameters as L<RPi::Gyro::MPU6050::Deadband/new>
(C<threshold>, C<window>) and returns the new filter object.

=head1 TECHNICAL INFORMATION

=head2 DEVICE SPECIFICS

    - 3-axis gyroscope, 3-axis accelerometer, die temperature sensor
    - A 16-bit ADC behind every axis
    - Gyro full-scale: +/-250, 500, 1000 or 2000 deg/s
    - Accel full-scale: +/-2, 4, 8 or 16 g
    - Programmable low-pass filter, sample rate divider, 1024 byte FIFO
    - Interrupt pin (data ready, motion detection, FIFO overflow)
    - Auxiliary I2C master port for hanging a magnetometer off the chip
    - I2C up to 400 kHz; address 0x68 or 0x69 (the MPU-6000 adds SPI)
    - Supply 2.375-3.46 V at roughly 4 mA all-on; separate VLOGIC pin
    - Powers up asleep, at +/-2 g and +/-250 deg/s, on its internal
      8 MHz oscillator

Wiring a GY-521 breakout to the Pi: VCC to 3.3v (the board's onboard
regulator also tolerates 5v), GND to ground, SDA to GPIO 2 (pin 3), SCL
to GPIO 3 (pin 5). Leave AD0 unconnected (or ground it) for address
C<0x68>; tie it high for C<0x69>. XDA/XCL are the auxiliary I2C bus and
INT is the interrupt output - all optional. Verify the chip answers
with C<i2cdetect -y 1>.

=head2 SCALING

Every measurement register is a 16-bit two's complement value, scaled
by the active full-scale range. The LSB sensitivities (these are the
datasheet's published values - note the gyro's aren't exact halvings):

    AFS_SEL   accel range   LSB/g        FS_SEL   gyro range      LSB/deg/s
    0         +/-2 g        16384        0        +/-250 deg/s    131
    1         +/-4 g        8192         1        +/-500 deg/s    65.5
    2         +/-8 g        4096         2        +/-1000 deg/s   32.8
    3         +/-16 g       2048         3        +/-2000 deg/s   16.4

L</accel> and L</gyro> divide the raw counts by the sensitivity of
whatever range is active. Temperature is fixed-scale:

    degrees C = TEMP_OUT / 340 + 36.53

=head2 DATA CONSISTENCY

The measurement registers are double-buffered: an internal set updates
at the sample rate, and the user-facing set copies from it only while
the serial interface is idle. A burst read therefore returns values
from a single sampling instant, while separate single-byte reads can
straddle a sample boundary and pair a fresh high byte with a stale low
byte.

L</accel>, L</gyro> and L</temp> burst-read for exactly this reason. If
you read measurement registers yourself via L</register>, you're in
single-byte territory - fine for poking around, but use this API (or
the data ready interrupt) when it matters.

=head2 SAMPLE RATE AND FILTERING

The sensor registers update at the sample rate:

    sample rate = gyro output rate / (1 + SMPLRT_DIV)

where the gyro output rate is 8 kHz with the low-pass filter off
(C<DLPF_CFG> 0 or 7) and 1 kHz with it on, and C<SMPLRT_DIV> is
register C<0x19>. The accelerometer always samples at 1 kHz.

The shared digital low-pass filter lives in C<DLPF_CFG> (register
C<0x1A>, bits 2:0):

    DLPF_CFG    accel bandwidth    gyro bandwidth    gyro rate
    0           260 Hz             256 Hz            8 kHz
    1           184 Hz             188 Hz            1 kHz
    2           94 Hz              98 Hz             1 kHz
    3           44 Hz              42 Hz             1 kHz
    4           21 Hz              20 Hz             1 kHz
    5           10 Hz              10 Hz             1 kHz
    6           5 Hz               5 Hz              1 kHz

The power-on default is 0 (wide open). For slow work like tilt
sensing, a setting of 3-6 via C<< $mpu->register(0x1A, $cfg) >> quiets
the readings considerably.

=head2 CLOCKING AND POWER

C<PWR_MGMT_1> (register C<0x6B>) holds the reset, sleep and clock
controls. The clock source (C<CLKSEL>, bits 2:0) defaults to the
internal 8 MHz oscillator, but the datasheet strongly recommends a gyro
PLL for stability - C<new()> selects the X gyro PLL (C<CLKSEL> 1) when
it wakes the chip.

Beyond L</sleep>, the chip has finer-grained economy modes, reachable
via L</register>: C<CYCLE> mode (bit 5 of C<0x6B>) naps between
periodic accelerometer-only samples at 1.25, 5, 20 or 40 Hz
(C<LP_WAKE_CTRL> in C<0x6C>), and C<PWR_MGMT_2> (C<0x6C>) can stand
down individual gyro and accel axes.

=head2 REGISTER MAP

    0x0D-0x10   SELF_TEST_*        Factory trim values for self-test
    0x19        SMPLRT_DIV         Sample rate divider
    0x1A        CONFIG             FSYNC pin and low-pass filter config
    0x1B        GYRO_CONFIG        Gyro self-test and full-scale range
    0x1C        ACCEL_CONFIG       Accel self-test and full-scale range
    0x1F        MOT_THR            Motion detection threshold
    0x23        FIFO_EN            Which sensors feed the FIFO
    0x24-0x36   I2C_MST/SLV*       Auxiliary I2C master and slaves 0-4
    0x37-0x3A   INT_*              Interrupt pin config, enables, status
    0x3B-0x40   ACCEL_*OUT         Accelerometer measurements
    0x41-0x42   TEMP_OUT           Temperature measurement
    0x43-0x48   GYRO_*OUT          Gyroscope measurements
    0x49-0x60   EXT_SENS_DATA      Auxiliary slave read results
    0x63-0x67   I2C_SLV*_DO        Auxiliary slave writes and delays
    0x68        SIGNAL_PATH_RESET  Per-sensor signal path resets
    0x69        MOT_DETECT_CTRL    Motion detection timing
    0x6A        USER_CTRL          FIFO/aux master enables and resets
    0x6B        PWR_MGMT_1         Reset, sleep, cycle, clock select
    0x6C        PWR_MGMT_2         Wake-up rate, per-axis standby
    0x72-0x73   FIFO_COUNT         Bytes waiting in the FIFO
    0x74        FIFO_R_W           FIFO read/write port
    0x75        WHO_AM_I           Identity; always reads 0x68

Every register resets to C<0x00> except C<PWR_MGMT_1> (C<0x40>,
asleep) and C<WHO_AM_I> (C<0x68>).

=head2 BEYOND THIS API

Everything below is reachable through L</register>:

B<FIFO>: route any mix of sensors into the 1024 byte FIFO (C<0x23>),
enable it in C<USER_CTRL> (C<0x6A>), then drain
C<FIFO_COUNT>/C<FIFO_R_W> (C<0x72>-C<0x74>) - batch collection without
a hard real-time loop on the Pi's side.

B<Interrupts>: the INT pin can signal data ready, FIFO overflow, or
hardware motion detection (threshold in C<MOT_THR>, C<0x1F>); configure
via C<0x37>-C<0x38> and read the latched status at C<0x3A>. Pair it
with L<RPi::Pin>'s interrupt support on a GPIO.

B<Auxiliary I2C>: the chip can master up to five external slave devices
(typically a magnetometer) and merge their data into its own register
map and FIFO - or set the bypass bit in C<INT_PIN_CFG> (C<0x37>) to
patch the auxiliary bus straight through to the Pi.

B<Self-test>: each axis can electrostatically actuate itself and
compare against factory trim (C<0x0D>-C<0x10>, plus the C<*_ST> bits in
the config registers).

The on-chip Digital Motion Processor (DMP) can fuse the gyro and accel
in hardware, but programming it requires loading InvenSense's firmware
image - out of scope for this module.

=head2 I2C ADDRESSING

The C<AD0> pin selects the address' low bit: low for C<0x68>, high for
C<0x69>, so two MPU-6050s can share a bus. C<WHO_AM_I> reports the
upper six address bits only - it reads C<0x68> no matter where C<AD0>
sits, which is why it works as an identity check.

=head1 SEE ALSO

L<RPi::I2C>, which provides the I2C transport for this distribution.

The MPU-6000/MPU-6050 register map and descriptions document:
L<https://cdn.sparkfun.com/datasheets/Sensors/Accelerometers/RM-MPU-6000A.pdf>

=head1 AUTHOR

Steve Bertrand, C<< <steveb at cpan.org> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Steve Bertrand.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>
