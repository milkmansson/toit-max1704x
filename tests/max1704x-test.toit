// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Hardware-free tests for the MAX1704x driver.

The chip is simulated by a byte-addressed register bank, so the register
  layout, masks and unit conversions are all exercised.  Expected raw values
  below are worked out by hand from the datasheet, not from the driver.
*/

import expect show *
import serial.device as serial
import serial.registers as registers
import max1704x show *

class MockRegisters extends registers.Registers:
  memory/ByteArray := ByteArray 256
  reset-count/int := 0
  nack-on-reset/bool := false

  constructor:
    super
    power-on-defaults

  power-on-defaults -> none:
    memory = ByteArray 256
    // Power-on defaults from datasheet Table 2.
    set-u16 0x08 0x0012       // VERSION (0x001_)
    set-u16 0x0A 0x8030       // HIBRT
    set-u16 0x0C 0x971C       // CONFIG: RCOMP=0x97, ATHD=0x1C (4%)
    set-u16 0x14 0x00FF       // VALRT: min 0, max 0xFF
    set-u16 0x18 0x9600       // VRESET=0x4B (3.0V), Dis=0, ID=0
    set-u16 0x1A 0x0100       // STATUS: reset indicator set

  set-u16 reg/int value/int -> none:
    memory[reg] = value >> 8
    memory[reg + 1] = value & 0xFF

  get-u16 reg/int -> int:
    return (memory[reg] << 8) | memory[reg + 1]

  read-bytes register/int count/int -> ByteArray:
    return memory[register..register + count]

  write-bytes register/int data/ByteArray -> none:
    if register == 0xFE:
      reset-count++
      if (data[0] << 8 | data[1]) == 0x5400:
        power-on-defaults
      if nack-on-reset: throw "I2C_WRITE_FAILED"
      return
    if register == 0x1A:
      // The alert flags are cleared by writing 0 and ignore a written 1.
      old := get-u16 0x1A
      written := (data[0] << 8) | data[1]
      set-u16 0x1A ((old & written & 0x3F00) | (written & ~0x3F00 & 0xFFFF))
      return
    memory.replace register data

class MockDevice implements serial.Device:
  registers/MockRegisters := MockRegisters
  read amount/int -> ByteArray: unreachable
  write bytes/ByteArray -> none: unreachable

expect-close expected/num actual/num --tolerance/float=1e-9:
  expect (expected - actual).abs <= tolerance --message="expected $expected, got $actual"

main:
  test-read-conversions
  test-variant-17049
  test-fields-do-not-clobber
  test-hibernation
  test-alerts
  test-reset-voltage-and-comparator
  test-sleep-and-quickstart
  test-status-flags
  test-rcomp
  test-reset
  test-is-ready
  test-estimates
  print "All tests passed."

new-driver -> List:
  dev := MockDevice
  return [Max1704x dev, dev.registers]

test-read-conversions:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]

  // 3.7 V = 47360 LSB of 78.125 uV.
  r.set-u16 0x02 47360
  expect-close 3.7 d.read-cell-voltage
  r.set-u16 0x02 0xFFFF
  expect-close (65535 * 78.125e-6) d.read-cell-voltage

  // SOC: 1/256 % per LSB. 0x5A80 = 90.5%, 0x6400 = 100%.
  r.set-u16 0x04 0x5A80
  expect-close 90.5 d.read-cell-state-of-charge
  r.set-u16 0x04 0x6400
  expect-close 100.0 d.read-cell-state-of-charge

  // Charge rate: signed, 0.208 %/h per LSB.
  r.set-u16 0x16 16
  expect-close (16 * 0.208) d.read-cell-charge-rate
  r.set-u16 0x16 0xFFF0           // -16
  expect-close (-16 * 0.208) d.read-cell-charge-rate
  r.set-u16 0x16 0x8000
  expect-close (-32768 * 0.208) d.read-cell-charge-rate

  expect-equals 0x0012 d.get-chip-version
  r.set-u16 0x18 0x9642
  expect-equals 0x42 d.get-chip-id

test-variant-17049:
  dev := MockDevice
  d := Max1704x dev --variant=Max1704x.VARIANT-MAX17049
  dev.registers.set-u16 0x02 47360
  // The 2-cell part reports per-cell units: pack voltage is twice as large.
  expect-close 7.4 d.read-cell-voltage
  expect-throw "INVALID_ARGUMENT": Max1704x dev --variant=17043

test-fields-do-not-clobber:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]
  // Writing one field must leave its neighbours intact.
  expect-equals 4 d.get-soc-empty-alert-threshold         // power-on default
  d.set-rcomp-value 0x55
  expect-equals 0x55 d.get-rcomp-value
  expect-equals 0x551C (r.get-u16 0x0C)       // ATHD = 32 - 4 = 28 = 0x1C
  d.set-soc-empty-alert-threshold 10
  expect-equals 0x55 d.get-rcomp-value
  expect-equals 10 d.get-soc-empty-alert-threshold
  expect-equals 0x5516 (r.get-u16 0x0C)       // ATHD = 22 = 0x16
  d.set-soc-empty-alert-threshold 4
  d.set-soc-change-alert-enabled true
  expect-equals 0x555C (r.get-u16 0x0C)
  expect d.get-soc-change-alert-enabled
  expect-equals 4 d.get-soc-empty-alert-threshold
  // The deprecated names still work.
  d.set-SOC-empty-alert-threshold 7
  expect-equals 7 d.get-SOC-empty-alert-threshold
  expect-equals 7 d.get-soc-empty-alert-threshold
  d.set-soc-empty-alert-threshold 4
  expect-throw "OUT_OF_RANGE": d.set-rcomp-value 0x100
  expect-throw "OUT_OF_RANGE": d.set-rcomp-value -1

test-hibernation:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]

  // Power-on defaults: HibThr 0x80, ActThr 0x30.
  expect-close (0x80 * 0.208) d.get-hibernation-hib-threshold
  expect-close (0x30 * 0.00125) d.get-hibernation-act-threshold

  // Activity threshold: 1.25 mV per LSB, low byte.
  d.set-hibernation-act-threshold 0.05      // 40 LSB
  expect-equals 40 (r.get-u16 0x0A) & 0xFF
  expect-close 0.05 d.get-hibernation-act-threshold
  d.set-hibernation-act-threshold 0.31875   // 255 LSB, the maximum
  expect-equals 0xFF (r.get-u16 0x0A) & 0xFF
  expect-throw "OUT_OF_RANGE": d.set-hibernation-act-threshold 0.32
  expect-throw "OUT_OF_RANGE": d.set-hibernation-act-threshold -0.01

  // Hibernate threshold: 0.208 %/h per LSB, high byte.
  d.set-hibernation-hib-threshold 2.08      // 10 LSB
  expect-equals 10 (r.get-u16 0x0A) >> 8
  expect-equals 0xFF (r.get-u16 0x0A) & 0xFF   // untouched (set above)
  expect-close 2.08 d.get-hibernation-hib-threshold
  d.set-hibernation-hib-threshold 53.0      // rounds to 255
  expect-equals 0xFF (r.get-u16 0x0A) >> 8
  expect-throw "OUT_OF_RANGE": d.set-hibernation-hib-threshold 54.0

  d.set-hibernate-mode-disabled
  expect-equals 0x0000 (r.get-u16 0x0A)
  expect (not d.get-hibernate-mode-enabled)
  d.set-hibernate-mode-enabled
  expect-equals 0xFFFF (r.get-u16 0x0A)
  expect d.get-hibernate-mode-enabled

  // Hibernating status: MODE bit 12.
  expect (not d.is-hibernating)
  r.set-u16 0x06 0x1000
  expect d.is-hibernating

test-alerts:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]

  // VALRT: min in high byte, max in low byte, 20 mV per LSB.
  d.set-voltage-alert-min 3.0               // 150
  d.set-voltage-alert-max 4.2               // 210
  expect-equals 0x96D2 (r.get-u16 0x14)
  expect-close 3.0 d.get-voltage-alert-min
  expect-close 4.2 d.get-voltage-alert-max
  d.set-voltage-alert-max 5.1               // 255
  expect-equals 0x96FF (r.get-u16 0x14)
  expect-throw "OUT_OF_RANGE": d.set-voltage-alert-max 5.2
  expect-throw "OUT_OF_RANGE": d.set-voltage-alert-min -0.1
  d.set-voltage-alert-min 3                 // Integers are accepted too.
  expect-close 3.0 d.get-voltage-alert-min
  expect-equals 0x96FF (r.get-u16 0x14)     // failed writes changed nothing

  // ALRT bit: CONFIG bit 5.
  expect (not d.alert)
  r.set-u16 0x0C (r.get-u16 0x0C) | 0x0020
  expect d.alert
  d.clear-alert
  expect (not d.alert)
  expect-equals 0x97 d.get-rcomp-value
  expect-equals 4 d.get-soc-empty-alert-threshold

  // SOC empty threshold covers 1..32%.
  d.set-soc-empty-alert-threshold 32
  expect-equals 32 d.get-soc-empty-alert-threshold
  d.set-soc-empty-alert-threshold 1
  expect-equals 1 d.get-soc-empty-alert-threshold
  expect-throw "OUT_OF_RANGE": d.set-soc-empty-alert-threshold 0
  expect-throw "OUT_OF_RANGE": d.set-soc-empty-alert-threshold 33

test-reset-voltage-and-comparator:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]
  r.set-u16 0x18 0x0042                     // ID = 0x42

  // VRESET: 40 mV per LSB, bits 15:9.
  d.set-reset-voltage 3.0                   // 75
  expect-equals (75 << 9 | 0x42) (r.get-u16 0x18)
  expect-close 3.0 d.get-reset-voltage
  d.set-reset-voltage 2.5                   // 62.5 -> 63 (rounded)
  expect-close (63 * 0.04) d.get-reset-voltage
  d.set-reset-voltage 5.08                  // 127, the maximum
  expect-equals 127 (r.get-u16 0x18) >> 9
  expect-throw "OUT_OF_RANGE": d.set-reset-voltage 5.2
  expect-throw "OUT_OF_RANGE": d.set-reset-voltage -0.04
  expect-equals 0x42 d.get-chip-id

  // Dis bit (bit 8): set means the analog comparator is DISABLED.
  d.set-hibernate-analog-comparator-enabled true
  expect-equals 0 (r.get-u16 0x18) & 0x0100
  expect d.get-hibernate-analog-comparator-enabled
  d.set-hibernate-analog-comparator-enabled false
  expect-equals 0x0100 (r.get-u16 0x18) & 0x0100
  expect (not d.get-hibernate-analog-comparator-enabled)
  expect-equals 127 (r.get-u16 0x18) >> 9
  expect-equals 0x42 d.get-chip-id

test-sleep-and-quickstart:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]

  expect (not d.get-sleep-mode-enabled)
  d.force-sleep-now                         // refused: not enabled
  expect-equals 0 (r.get-u16 0x0C) & 0x0080
  d.set-sleep-mode-enabled true
  expect-equals 0x2000 (r.get-u16 0x06)     // MODE bit 13
  expect d.get-sleep-mode-enabled
  d.force-sleep-now
  expect-equals 0x0080 (r.get-u16 0x0C) & 0x0080   // CONFIG bit 7
  expect-equals 0x97 d.get-rcomp-value
  d.force-wake-now
  expect-equals 0 (r.get-u16 0x0C) & 0x0080
  d.set-sleep-mode-enabled false
  expect (not d.get-sleep-mode-enabled)

  d.set-sleep-mode-enabled true
  d.set-quickstart
  expect-equals 0x4000 (r.get-u16 0x06) & 0x4000   // MODE bit 14
  expect d.get-sleep-mode-enabled                  // sleep setting is kept (MODE bit 13)
  // MODE is write-only: a stale quick-start bit must never be written back.
  d.set-sleep-mode-enabled false
  expect-equals 0 (r.get-u16 0x06) & 0x4000
  d.set-sleep-mode-enabled true
  expect-equals 0x2000 (r.get-u16 0x06)

test-status-flags:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]
  // Reset indicator is set at power-on.
  expect (d.check-status Max1704x.STATUS-RESET-INDICATOR)
  expect (not (d.check-status Max1704x.STATUS-VOLTAGE-LOW))
  r.set-u16 0x1A 0x0100 | 0x0400 | 0x2000
  expect (d.check-status Max1704x.STATUS-VOLTAGE-LOW)
  expect (d.check-status Max1704x.STATUS-SOC-CHANGE)
  expect (not (d.check-status Max1704x.STATUS-VOLTAGE-HIGH))
  expect (not (d.check-status Max1704x.STATUS-SOC-LOW))
  expect (not (d.check-status Max1704x.STATUS-VOLTAGE-RESET))

  d.set-vreset-alert-enabled true
  expect-equals 0x4000 (r.get-u16 0x1A) & 0x4000
  expect d.get-vreset-alert-enabled
  expect (d.check-status Max1704x.STATUS-VOLTAGE-LOW)   // untouched

  d.clear-status-flags Max1704x.STATUS-VOLTAGE-LOW
  expect (not (d.check-status Max1704x.STATUS-VOLTAGE-LOW))
  expect (d.check-status Max1704x.STATUS-SOC-CHANGE)    // other flags remain
  expect d.get-vreset-alert-enabled                     // enable bit remains
  expect-throw "INVALID_ARGUMENT": d.clear-status-flags 0x0001

  // Writing the status register never raises a flag.
  d.set-vreset-alert-enabled false
  expect (not d.get-vreset-alert-enabled)
  expect (not (d.check-status Max1704x.STATUS-VOLTAGE-HIGH))
  expect (not (d.check-status Max1704x.STATUS-SOC-LOW))
  expect (d.check-status Max1704x.STATUS-SOC-CHANGE)
  d.clear-status-flags Max1704x.STATUS-SOC-CHANGE | Max1704x.STATUS-RESET-INDICATOR
  expect-equals 0 (r.get-u16 0x1A) & 0x3F00

test-rcomp:
  // RCOMP = 0x97 + (T-20) * -0.5 above 20C, and + (T-20) * -5.0 below.
  expect-equals 0x97 (Max1704x.calculate-rcomp 20.0)
  expect-equals 0x97 (Max1704x.calculate-rcomp 20)
  expect-equals (0x97 - 5) (Max1704x.calculate-rcomp 30.0)     // -0.5*10
  expect-equals (0x97 + 50) (Max1704x.calculate-rcomp 10.0)    // -5.0*-10
  expect-equals (0x97 + 100) (Max1704x.calculate-rcomp 0.0)
  expect-equals 255 (Max1704x.calculate-rcomp -40.0)           // clamped
  expect-equals 0 (Max1704x.calculate-rcomp 500.0)             // clamped
  expect-equals (0x97 - 3) (Max1704x.calculate-rcomp 26.0)     // -3.0
  expect-equals 0x10 (Max1704x.calculate-rcomp 20.0 --rcomp0=0x10)

  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]
  d.set-soc-empty-alert-threshold 8
  d.set-temperature-compensation 10.0
  expect-equals (0x97 + 50) d.get-rcomp-value
  expect-equals 8 d.get-soc-empty-alert-threshold
  // Repeated calls must not accumulate.
  d.set-temperature-compensation 10.0
  d.set-temperature-compensation 10.0
  expect-equals (0x97 + 50) d.get-rcomp-value
  d.set-temperature-compensation 20.0
  expect-equals 0x97 d.get-rcomp-value
  d.set-temperature-compensation
  expect-equals 0x97 d.get-rcomp-value

test-reset:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]
  d.set-rcomp-value 0x20
  d.reset
  expect-equals 1 r.reset-count
  expect-equals 0x97 d.get-rcomp-value             // back to defaults
  expect (not (d.check-status Max1704x.STATUS-RESET-INDICATOR))

  // The chip does not ACK the reset command: the driver must cope.
  r.nack-on-reset = true
  d.set-rcomp-value 0x20
  d.reset
  expect-equals 2 r.reset-count
  expect-equals 0x97 d.get-rcomp-value

test-is-ready:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]
  expect d.is-ready
  r.set-u16 0x08 0xFFFF
  expect (not d.is-ready)
  r.set-u16 0x08 0x0000
  expect (not d.is-ready)

  // A device that fails on read is "not ready", rather than an exception.
  dev := MockDevice
  dev.registers = FailingRegisters
  expect (not (Max1704x dev).is-ready)

class FailingRegisters extends MockRegisters:
  read-bytes register/int count/int -> ByteArray:
    throw "I2C_READ_FAILED"

test-estimates:
  pair := new-driver
  d/Max1704x := pair[0]
  r/MockRegisters := pair[1]

  // Not configured: explicit errors, not nonsense.
  expect-throw "design capacity (mAh) not set": d.estimate-mah-remaining
  expect-throw "design capacity (Wh) not set": d.estimate-wh-remaining

  expect-throw "design capacity (mAh) not set": d.estimate-state-of-health --current-a=0.37
  expect-throw "design capacity (mAh) not set": d.estimate-expected-charge-rate --current-a=0.37
  // The effective capacity does not depend on the design capacity.
  expect-close 3700.0 (d.estimate-effective-capacity-mah --current-a=0.37 --charge-rate-pct=-10.0) --tolerance=1e-6

  d.set-design-capacity-mah 3700
  d.set-design-capacity-wh 13.7
  r.set-u16 0x04 0x3200                     // 50%
  expect-close 1850.0 d.estimate-mah-remaining
  expect-close 6.85 d.estimate-wh-remaining

  // 1850 mAh at 0.5 A (500 mA) = 3.7 hours.  (Amps vs mA used to be mixed up.)
  expect-close 3.7 (d.estimate-hours-left --current-a=0.5) --tolerance=1e-6
  expect-close 3.7 (d.estimate-hours-left --current-a=-0.5) --tolerance=1e-6
  expect-close 1e9 (d.estimate-hours-left --current-a=0.0)

  // 0.37 A on a 3700 mAh pack is 0.1 C = 10 %/h.
  expect-close 10.0 (d.estimate-expected-charge-rate --current-a=0.37) --tolerance=1e-9
  expect-close -10.0 (d.estimate-expected-charge-rate --current-a=-0.37) --tolerance=1e-9
  expect-close 10.0 (d.estimate-expected-crate-pct_per_hr --current-a=0.37) --tolerance=1e-9   // Deprecated name.

  // Hours left from charge rate: 50% at -10 %/h = 5 h.
  expect-close 5.0 (d.estimate-hours-left --charge-rate-pct=-10.0)
  expect-close 1e9 (d.estimate-hours-left --charge-rate-pct=0.0)
  expect-close 1e9 (d.estimate-hours-left --charge-rate-pct=2.0)
  // And using the register: raw -48 = -9.984 %/h.
  r.set-u16 0x16 0xFFD0
  expect-close (50.0 / 9.984) d.estimate-hours-left --tolerance=1e-9

  // Effective capacity: 0.37 A = 370 mA draining 10 %/h means 3700 mAh.
  expect-close 3700.0 (d.estimate-effective-capacity-mah --current-a=0.37 --charge-rate-pct=-10.0) --tolerance=1e-6
  expect-close 3700.0 (d.estimate-effective-capacity-mah --current-a=-0.37 --charge-rate-pct=10.0) --tolerance=1e-6
  expect-null (d.estimate-effective-capacity-mah --current-a=0.37 --charge-rate-pct=0.0)
  r.set-u16 0x16 0
  expect-null (d.estimate-state-of-health --current-a=0.37)
  r.set-u16 0x16 0xFFD0                     // -9.984 %/h
  soh := d.estimate-state-of-health --current-a=0.37
  expect-close (100.0 * 370.0 * 100.0 / 9.984 / 3700.0) soh --tolerance=1e-6

  // Hours to full: 50% of 3700 mAh = 1850 mAh missing at 370 mA = 5 h, +20%.
  expect-close 6.0 (d.estimate-hours-to-full --current-a=0.37) --tolerance=1e-9
  expect-close 1e9 (d.estimate-hours-to-full --current-a=0.0)
  expect-close 1e9 (d.estimate-hours-to-full --current-a=-0.37)
  r.set-u16 0x04 0x6400                     // 100%
  expect-close 0.0 (d.estimate-hours-to-full --current-a=0.37)
