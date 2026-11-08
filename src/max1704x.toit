// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.   This file also includes derivative
// work from other authors and sources.  See accompanying documentation.
//
// Original IC Datasheet can be found at:
// https://www.analog.com/media/en/technical-documentation/data-sheets/MAX17048-MAX17049.pdf
//

import serial.device as serial
import serial.registers as registers
import log

/**
Toit driver for the MAX17048/MAX17049 single and dual cell LiPo fuel gauge ICs.

See the README for details on the alerts, sleep, hibernation and quick-start
  features.
*/
class Max1704x:

  static I2C-ADDRESS                   ::= 0x36   // Not configurable

  // Datasheet page 11.
  static REG-CONFIG_                   ::= 0x0C   // Configuration register
  static REG-STATUS_                   ::= 0x1A   // Current alert/status
  static REG-MODE_                     ::= 0x06   // Mode register

  static REG-SOC_                      ::= 0x04   // Cell state of charge register
  static REG-CELL-VOLTAGE_             ::= 0x02   // Cell voltage register
  static REG-CHARGE-RATE_              ::= 0x16   // Cell charge rate register

  static REG-VOLTAGE-RESET-ID_         ::= 0x18   // Reset voltage settings (and ID) register
  static REG-VOLTAGE-ALERT_            ::= 0x14   // Voltage alert values register

  static REG-HIBERNATE_                ::= 0x0A   // Hibernation configuration register
  static REG-VERSION_                  ::= 0x08   // Holds IC version

  static REG-CMD_                      ::= 0xFE   // Register that can be written for special commands

  // For use with REG-CMD_
  static POWER-ON-RESET-VALUE_         ::= 0x5400

  // For use with $REG-MODE_
  static MODE-QUICK-START-MODE-MASK_   ::= 0b01000000_00000000
  static MODE-SLEEP-ENABLED-MASK_      ::= 0b00100000_00000000
  static MODE-HIBERNATING-MASK_        ::= 0b00010000_00000000

  // For use with $REG-CONFIG_
  static CHEMISTRY-RCOMP-MASK_         ::= 0b11111111_00000000
  static SLEEP-MASK_                   ::= 0b00000000_10000000
  static ALERT-SOC-CHANGE-MASK_        ::= 0b00000000_01000000   // Alert flag for state-of-charge change
  static ALERT-MASK_                   ::= 0b00000000_00100000   // Alert flag equal to pin operation
  static EMPTY-ALERT-THRESHOLD-MASK_   ::= 0b00000000_00011111   // Alerts that cell is empty below the threshold.

  // For use with VRESET/ID Register (0x18)
  static VRESET-MASK_                  ::= 0b11111110_00000000
  static HIBERNATE-DIS-ANALOG-CO-MASK_ ::= 0b00000001_00000000
  static CHIP-ID-MASK_                 ::= 0b00000000_11111111

  // For use with $REG-HIBERNATE_
  static HIBERNATE-HIB-THRESHOLD-MASK_ ::= 0b11111111_00000000
  static HIBERNATE-ACT-THRESHOLD-MASK_ ::= 0b00000000_11111111

  // For use with $REG-VOLTAGE-ALERT_
  static ALERT-VOLTAGE-MIN-MASK_       ::= 0b11111111_00000000
  static ALERT-VOLTAGE-MAX-MASK_       ::= 0b00000000_11111111

  // For use with $REG-STATUS_
  // The STATUS-* flags are public, for use with $check-status and $clear-status-flags.
  static STATUS-RESET-INDICATOR        ::= 0b00000001_00000000  // Set when unconfigured, no model loaded.
  static STATUS-VOLTAGE-HIGH           ::= 0b00000010_00000000  // V(cell) above ALRT.VALRTMAX.
  static STATUS-VOLTAGE-LOW            ::= 0b00000100_00000000  // V(cell) below ALRT.VALRTMIN.
  static STATUS-VOLTAGE-RESET          ::= 0b00001000_00000000  // Set if device has been reset (if EnVr is set).
  static STATUS-SOC-LOW                ::= 0b00010000_00000000  // Set when SOC crosses the value in CONFIG.ATHD.
  static STATUS-SOC-CHANGE             ::= 0b00100000_00000000  // Set when SOC changes by at least 1% (if CONFIG.ALSC is set)
  static STATUS-ALL-ALERTS_            ::= 0b00111111_00000000
  static VRESET-ALERT-ENABLE-MASK_     ::= 0b01000000_00000000  // Enable or Disable VRESET Alert

  // Chip variants, for use with the constructor.
  static VARIANT-MAX17048              ::= 48   // Single cell.
  static VARIANT-MAX17049              ::= 49   // Two cells in series.

  static soc-rate-lsb_                 ::= 0.00390625    // 1% / 256  LSB
  static cell-voltage-lsb_             ::= 0.000078125   // 78.125 µV/LSB (i.e., 78.125e-6)
  static charge-rate-lsb-pct_          ::= 0.208         //  0.208% / LSB
  static hibernation-lsb-v_            ::= 0.00125       //  1.25mv / LSB
  static voltage-alert-lsb-v_          ::= 0.02          // 20mV / LSB
  static voltage-reset-lsb-v_          ::= 0.04          // 40mV    / LSB

  // For use with RCOMP tuning parameters
  static RCOMP0                        ::= 0x97
  static TEMP-COMPENSATION-UP          ::= -0.5   // Per degree C above 20C.
  static TEMP-COMPENSATION-DOWN        ::= -5.0   // Per degree C below 20C.

  // Returned by the estimate functions when the result is effectively unbounded.
  static INFINITE-HOURS_               ::= 1e9

  // Class private variables
  reg_/registers.Registers := ?
  logger_/log.Logger := ?
  cells_/int := 1

  /**
  Constructs the driver.

  Use $VARIANT-MAX17049 for the two-cell part: its VCELL register reports half
    the pack voltage per LSB, so $read-cell-voltage needs to scale it.
  */
  constructor dev/serial.Device --variant/int=VARIANT-MAX17048 --logger/log.Logger=log.default:
    if variant != VARIANT-MAX17048 and variant != VARIANT-MAX17049: throw "INVALID_ARGUMENT"
    logger_ = logger.with-name "max1704x"
    reg_ = dev.registers
    cells_ = variant == VARIANT-MAX17049 ? 2 : 1

  /**
  Resets the device.

  Writing a value of 0x5400 to the command register causes the device to
   completely reset as if power had been removed (see the Power-On Reset (POR)
   section).  The reset occurs when the last bit has been clocked in. The IC does
   not respond with an I2C ACK after this command sequence.

  The first SOC update is available approximately 1s after the reset, so allow
   for that before relying on $read-cell-state-of-charge.  A reset includes a
   quick-start, so only use it when the battery is relaxed.
  */
  reset -> none:
    // The IC does not ACK the last byte of this command, so a bus error here
    // is expected.
    catch: write-register_ REG-CMD_ POWER-ON-RESET-VALUE_
    sleep --ms=250

    // The reset sets the reset indicator.  Clear it, and check that it stuck.
    clear-reset-indicator_
    if get-reset-indicator_:
      logger_.debug "reset: reset-indicator still set, retrying after 1s..."
      sleep --ms=1100
      clear-reset-indicator_
      if get-reset-indicator_:
        logger_.warn "reset: reset-indicator not cleared. Ignoring..."

  /** Whether the Reset Indicator is tripped. */
  get-reset-indicator_ -> bool:
    out := read-register_ REG-STATUS_ --mask=STATUS-RESET-INDICATOR
    return (out == 1)

  /**
  Clears the Reset Indicator.
  */
  clear-reset-indicator_ -> none:
    write-register_ REG-STATUS_ 0 --mask=STATUS-RESET-INDICATOR

  /** Gets the chip version.  Indicates the production version of the IC. */
  get-chip-version -> int:
    return read-register_ REG-VERSION_

  /**
  Gets Chip ID. (Datasheet pp13).

  Value that is one-time programmable at the factory, which can be used as
   an identifier to distinguish multiple cell types in production.
  */
  get-chip-id -> int:
    return read-register_ REG-VOLTAGE-RESET-ID_ --mask=CHIP-ID-MASK_

  /**
  Gets the RCOMP value from the IC. (See Datasheet and README)
  */
  get-rcomp-value -> int:
    return read-register_ REG-CONFIG_ --mask=CHEMISTRY-RCOMP-MASK_

  /**
  Sets the RCOMP value in the IC. (See Datasheet and README)
  */
  set-rcomp-value value/int -> none:
    write-register_ REG-CONFIG_ value --mask=CHEMISTRY-RCOMP-MASK_

  /**
  Calculates the RCOMP value for the given $temperature (in Celsius).

  Uses the datasheet formula: $rcomp0 + (T - 20) * coefficient, where the
    coefficient depends on whether the temperature is above or below 20C.  The
    result is rounded and limited to the 8-bit range of the register.
  */
  static calculate-rcomp temperature/num --rcomp0/int=RCOMP0 -> int:
    coefficient := temperature > 20 ? TEMP-COMPENSATION-UP : TEMP-COMPENSATION-DOWN
    rcomp := rcomp0 + (temperature - 20) * coefficient
    return (max 0 (min 255 rcomp.round))

  /**
  Sets Temperature Compensation in the IC.

  The value is always calculated from $RCOMP0 (not the current register value),
    so this can be called repeatedly without drifting.  The $temperature is the
    battery temperature in Celsius.
  */
  set-temperature-compensation temperature/num=20.0 -> none:
    set-rcomp-value (calculate-rcomp temperature)

  /**
  Determines if an alert exists.

  When this bit is set, the ALRT pin asserts (is low). Use $clear-alert to de-assert
   the ALRT pin. The STATUS register ($read-status-raw) specifies why the ALRT
   pin was asserted.
  */
  alert -> bool:
    out := read-register_ REG-CONFIG_ --mask=ALERT-MASK_
    return out == 1

  /** Clears the alert, which de-asserts the ALRT pin. */
  clear-alert -> none:
    write-register_ REG-CONFIG_ 0 --mask=ALERT-MASK_

  /**
  Sets the 'SOC is empty now' alert $threshold, in percent (1 to 32).

  See the README.
  */
  set-soc-empty-alert-threshold threshold/int -> none:
    if not 1 <= threshold <= 32: throw "OUT_OF_RANGE"
    write-register_ REG-CONFIG_ (32 - threshold) --mask=EMPTY-ALERT-THRESHOLD-MASK_

  /**
  Gets the 'SOC is empty now' alert threshold, in percent.

  See the README.
  */
  get-soc-empty-alert-threshold -> int:
    out := read-register_ REG-CONFIG_ --mask=EMPTY-ALERT-THRESHOLD-MASK_
    return (32 - out)

  /** Deprecated.  Use $set-soc-empty-alert-threshold. */
  set-SOC-empty-alert-threshold threshold/int -> none:
    set-soc-empty-alert-threshold threshold

  /** Deprecated.  Use $get-soc-empty-alert-threshold. */
  get-SOC-empty-alert-threshold -> int:
    return get-soc-empty-alert-threshold

  /**
  Enables the ability to enter ultra-low-power sleep mode.

  Use true for $enabled to enable sleep mode (1uA draw), false to only allow
    hibernation.
  */
  set-sleep-mode-enabled enabled/bool -> none:
    // MODE is written whole rather than read-modified-written.  This way a
    // stale Quick-Start bit can never be written back, which would trigger
    // another quick-start.
    write-register_ REG-MODE_ (enabled ? MODE-SLEEP-ENABLED-MASK_ : 0)

  /**
  Whether the device has the ability to enter ultra-low-power sleep mode.

  See $set-sleep-mode-enabled.
  */
  get-sleep-mode-enabled -> bool:
    value := read-register_ REG-MODE_ --mask=MODE-SLEEP-ENABLED-MASK_
    return (value == 1)

  /**
  Forces the device into sleep mode, now.

  Requires sleep mode to be enabled beforehand, see $set-sleep-mode-enabled.
  */
  force-sleep-now -> none:
    if get-sleep-mode-enabled:
      write-register_ REG-CONFIG_ 1 --mask=SLEEP-MASK_
    else:
      logger_.error "sleep-now: Cannot sleep now as sleep mode not enabled."

  /**
  Forces the device out of sleep mode, now.

  Requires sleep mode to be enabled beforehand, see $set-sleep-mode-enabled.
  */
  force-wake-now -> none:
    if get-sleep-mode-enabled:
      write-register_ REG-CONFIG_ 0 --mask=SLEEP-MASK_
    else:
      logger_.error "wake-now: Cannot wake now as sleep mode not enabled."

  /**
  Sets the hibernation activity threshold, in volts. See the README or Datasheet.
  */
  set-hibernation-act-threshold volts/num -> none:
    value := to-raw_ volts hibernation-lsb-v_ 0xFF
    write-register_ REG-HIBERNATE_ value --mask=HIBERNATE-ACT-THRESHOLD-MASK_

  /**
  Gets the hibernation activity threshold, in volts. See the README or Datasheet.
  */
  get-hibernation-act-threshold -> float:
    value := read-register_ REG-HIBERNATE_ --mask=HIBERNATE-ACT-THRESHOLD-MASK_
    return value * hibernation-lsb-v_

  /**
  Sets hibernate threshold: the %/hour change triggering hibernation of the IC.
  */
  set-hibernation-hib-threshold percent/num -> none:
    value := to-raw_ percent charge-rate-lsb-pct_ 0xFF
    write-register_ REG-HIBERNATE_ value --mask=HIBERNATE-HIB-THRESHOLD-MASK_

  /**
  Gets hibernate threshold: the %/hour change triggering hibernation of the IC.
  */
  get-hibernation-hib-threshold -> float:
    value := read-register_ REG-HIBERNATE_ --mask=HIBERNATE-HIB-THRESHOLD-MASK_
    return value * charge-rate-lsb-pct_

  /**
  Sets the hibernate mode to be disabled:

  Datasheet states that setting the registers to = 0x0000 disables hibernation.
  To always use hibernate mode, set entire register = 0xFFFF. [See Datasheet pp.12]
  */
  set-hibernate-mode-disabled -> none:
    write-register_ REG-HIBERNATE_ 0x0000

  /**
  Sets the hibernate mode to be forced on, with maximum settings:

  Datasheet states that setting both hibernation registers to maximum will
    'enable' hibernation.  The device will be configured to its maximum values.
    [See Datasheet pp.12]
  */
  set-hibernate-mode-enabled -> none:
    write-register_ REG-HIBERNATE_ 0xFFFF

  /**
  Whether hibernate mode is enabled.

  Hibernation is disabled if either threshold is zero.
  */
  get-hibernate-mode-enabled -> bool:
    act-t := get-hibernation-act-threshold
    hib-t := get-hibernation-hib-threshold
    return (act-t > 0) and (hib-t > 0)

  /**
  Enables or disables the analog comparator used in hibernation.

  See the README and Datasheet.
  */
  set-hibernate-analog-comparator-enabled enabled/bool -> none:
    value := enabled ? 0 : 1
    write-register_ REG-VOLTAGE-RESET-ID_ value --mask=HIBERNATE-DIS-ANALOG-CO-MASK_

  /**
  Whether the analog comparator used in hibernation is enabled.

  See the README and Datasheet.
  */
  get-hibernate-analog-comparator-enabled -> bool:
    value := read-register_ REG-VOLTAGE-RESET-ID_ --mask=HIBERNATE-DIS-ANALOG-CO-MASK_
    return value == 0

  /**
  Sets alert-min voltage - Alerts when V(cell) < V(alert-min).
  */
  set-voltage-alert-min voltage/num -> none:
    value := to-raw_ voltage voltage-alert-lsb-v_ 0xFF
    write-register_ REG-VOLTAGE-ALERT_ value --mask=ALERT-VOLTAGE-MIN-MASK_

  /**
  Returns configured alert-min voltage.
  */
  get-voltage-alert-min -> float:
    value := read-register_ REG-VOLTAGE-ALERT_ --mask=ALERT-VOLTAGE-MIN-MASK_
    return value * voltage-alert-lsb-v_

  /**
  Sets the alert-max voltage - Alerts when V(cell) > V(alert-max).
  */
  set-voltage-alert-max voltage/num -> none:
    value := to-raw_ voltage voltage-alert-lsb-v_ 0xFF
    write-register_ REG-VOLTAGE-ALERT_ value --mask=ALERT-VOLTAGE-MAX-MASK_

  /**
  Returns configured alert-max voltage.
  */
  get-voltage-alert-max -> float:
    value := read-register_ REG-VOLTAGE-ALERT_ --mask=ALERT-VOLTAGE-MAX-MASK_
    return value * voltage-alert-lsb-v_

  /**
  Enables or disables the voltage reset alert.

  When enabled, asserts the ALRT pin when a voltage-reset event occurs under the
    conditions described by the VRESET/ID register.
  */
  set-vreset-alert-enabled enabled/bool -> none:
    update-status_
        --mask=VRESET-ALERT-ENABLE-MASK_
        --value=(enabled ? VRESET-ALERT-ENABLE-MASK_ : 0)

  /** Whether the voltage reset alert is enabled. */
  get-vreset-alert-enabled -> bool:
    return (read-register_ REG-STATUS_ --mask=VRESET-ALERT-ENABLE-MASK_) == 1

  /**
  Enables or disables the alert when the state of charge changes by at least 1%.

  The change is reported with $STATUS-SOC-CHANGE, and asserts the ALRT pin.
  */
  set-soc-change-alert-enabled enabled/bool -> none:
    write-register_ REG-CONFIG_ (enabled ? 1 : 0) --mask=ALERT-SOC-CHANGE-MASK_

  /** Whether the state-of-charge change alert is enabled. */
  get-soc-change-alert-enabled -> bool:
    return (read-register_ REG-CONFIG_ --mask=ALERT-SOC-CHANGE-MASK_) == 1

  /**
  Checks whether the given status $flag is set.

  The $flag is one of the STATUS-* statics, for example $STATUS-VOLTAGE-LOW.
  */
  check-status flag/int -> bool:
    return (read-status-raw & flag) != 0

  /** Reads the raw status register (also useful for troubleshooting). */
  read-status-raw -> int:
    return read-register_ REG-STATUS_

  /**
  Clears the given status $flags (one or more of the STATUS-* statics).

  Other bits, including the voltage reset alert enable, are left as they were.
  */
  clear-status-flags flags/int -> none:
    if flags & ~STATUS-ALL-ALERTS_ != 0: throw "INVALID_ARGUMENT"
    update-status_ --clear-flags=flags

  /**
  Reads cell charge-rate - as % change per hour. (Not for conversion to amps).
  */
  read-cell-charge-rate -> float:
    raw/int := reg_.read-i16-be REG-CHARGE-RATE_
    return raw * charge-rate-lsb-pct_

  /**
  Reads the cell voltage (in Volts).

  For the MAX17049 this is the voltage of the whole two-cell pack.
  */
  read-cell-voltage -> float:
    raw/int := read-register_ REG-CELL-VOLTAGE_
    return raw * cell-voltage-lsb_ * cells_

  /**
  Reads the cell state of charge (in %)
  */
  read-cell-state-of-charge -> float:
    value/int := read-register_ REG-SOC_
    return value * soc-rate-lsb_

  /**
  Checks if the MAX1704x is ready to be read from (True/False).

  MAX17049: Chip ID = 0xFF and Version = 0xFFFF if no battery is attached
  MAX17048: Power will be off if no battery is attached.

  Returns false if the device does not respond, or reports an invalid version.
  */
  is-ready -> bool:
    catch: return (get-chip-version & 0xFFF0) == 0x0010
    return false

  /**
  Whether the device is currently hibernating.
  */
  is-hibernating -> bool:
    raw := read-register_ REG-MODE_ --mask=MODE-HIBERNATING-MASK_
    return raw == 1

  /**
  Execute a 'Quickstart'.

  Use with caution.  See the README, and Datasheet page 9.
  */
  set-quickstart -> none:
    // MODE is written whole, see $set-sleep-mode-enabled.  Keep the sleep setting.
    sleep-bit := get-sleep-mode-enabled ? MODE-SLEEP-ENABLED-MASK_ : 0
    write-register_ REG-MODE_ (MODE-QUICK-START-MODE-MASK_ | sleep-bit)

  /**
  Sets the voltage the IC considers a 'reset'.  See the README and/or Datasheet.

  The datasheet guarantees the 2.28V to 3.48V range, in 40mV steps.
  */
  set-reset-voltage voltage/num -> none:
    value := to-raw_ voltage voltage-reset-lsb-v_ 0x7F   // 7 bit field
    write-register_ REG-VOLTAGE-RESET-ID_ value --mask=VRESET-MASK_

  /**
  Gets the voltage the IC considers a 'reset'.  See the README and/or Datasheet.
  */
  get-reset-voltage -> float:
    value := read-register_ REG-VOLTAGE-RESET-ID_ --mask=VRESET-MASK_
    return (value * voltage-reset-lsb-v_)

  // NOT YET IMPLEMENTED: TABLE Registers (0x40 to 0x7F)
  // Datasheets require contact with Maxim for details on how to configure these
  // registers. The default value is appropriate for some Li+ batteries.
  //
  // To unlock the TABLE registers, write 0x57 to address 0x3F, and 0x4A to
  // address 0x3E. While TABLE is unlocked, no ModelGauge registers are updated,
  // so relock as soon as possible by writing 0x00 to address 0x3F, and 0x00 to
  // address 0x3E.

  // EXPERIMENTAL
  //
  // The following functions are created somewhat experimentally.  The health and
  // actual capacities of batteries change over time, as well as actual values
  // varying by things like temperature and stress.  Please consider these
  // experimental in nature.
  //
  // Given the design capacity (mAh and Wh), several other pieces of information
  // can be derived.
  design-capacity-mah_/float := 0.0
  design-capacity-wh_/float  := 0.0

  /** Sets the design capacity of the battery, in mAh. */
  set-design-capacity-mah mah/num -> none:
    design-capacity-mah_ = mah.to-float

  /** Sets the design capacity of the battery, in Wh. */
  set-design-capacity-wh wh/num -> none:
    design-capacity-wh_  = wh.to-float

  /** Estimated remaining capacity, in mAh.  Requires $set-design-capacity-mah. */
  estimate-mah-remaining -> float:
    if design-capacity-mah_ <= 0.0: throw "design capacity (mAh) not set"
    return (design-capacity-mah_ * (read-cell-state-of-charge) / 100.0)

  /** Estimated remaining energy, in Wh.  Requires $set-design-capacity-wh. */
  estimate-wh-remaining -> float:
    if design-capacity-wh_ <= 0.0: throw "design capacity (Wh) not set"
    return (design-capacity-wh_ * (read-cell-state-of-charge) / 100.0)

  /**
  Estimated hours until empty, using the charge rate (in %/hour).

  Returns a very large number if the battery is not discharging.
  */
  estimate-hours-left --charge-rate-pct/float=(read-cell-charge-rate) -> float:
    if charge-rate-pct >= -1e-6: return INFINITE-HOURS_   // Not discharging.
    return read-cell-state-of-charge / charge-rate-pct.abs

  /**
  If a current meter (such as INA226, INA219 or INA3221) can measure and provide
  the current of the battery, further information can also be derived.

  Estimated hours until empty, given the present battery current in amps (the
    sign is ignored).  Requires $set-design-capacity-mah.
  */
  estimate-hours-left --current-a/num -> float:
    current-ma := current-a.abs * 1000.0
    if current-ma < 1e-3: return INFINITE-HOURS_
    return estimate-mah-remaining / current-ma

  /**
  The charge rate (in %/hour) that the given battery current (in amps) is
    expected to cause.  Requires $set-design-capacity-mah.
  */
  estimate-expected-charge-rate --current-a/num -> float:
    if design-capacity-mah_ <= 0.0: throw "design capacity (mAh) not set"
    return (current-a * 1000.0 / design-capacity-mah_) * 100.0

  /** Deprecated.  Use $estimate-expected-charge-rate. */
  estimate-expected-crate-pct_per_hr --current-a/num -> float:
    return estimate-expected-charge-rate --current-a=current-a

  /**
  Estimates the effective capacity (in mAh) from the present current (in amps)
    and charge rate (in %/hour).

  Returns null if the charge rate is too close to zero for a meaningful result.
  */
  estimate-effective-capacity-mah --current-a/num --charge-rate-pct/float=(read-cell-charge-rate) -> float?:
    if charge-rate-pct.abs < 0.05: return null    // Too small to be reliable.
    return (current-a * 1000.0).abs * 100.0 / charge-rate-pct.abs

  /**
  Estimates the state of health (in %): effective capacity vs design capacity.

  Returns null if it cannot be determined, see $estimate-effective-capacity-mah.
    Requires $set-design-capacity-mah.
  */
  estimate-state-of-health --current-a/num -> float?:
    if design-capacity-mah_ <= 0.0: throw "design capacity (mAh) not set"
    effective := estimate-effective-capacity-mah --current-a=current-a
    if effective == null: return null
    return 100.0 * effective / design-capacity-mah_

  /**
  Estimates hours until full, given the charging current in amps.

  The current is positive when charging. Returns a very large number if not
    charging.  Includes a 20% allowance for the charge taper.
  */
  estimate-hours-to-full --current-a/num -> float:
    if design-capacity-mah_ <= 0.0: throw "design capacity (mAh) not set"
    state-of-charge := read-cell-state-of-charge
    if state-of-charge >= 99.9:
      return 0.0
    current-ma := current-a * 1000.0
    if current-ma <= 1e-3: return INFINITE-HOURS_    // Not charging.
    missing-mAh := design-capacity-mah_ * ((100.0 - state-of-charge) / 100.0)
    return (missing-mAh / current-ma) * 1.2           // 1.2 fudge for taper

  /**
  Converts $value to a raw register value: value / lsb, rounded.

  Throws OUT_OF_RANGE unless the result is within 0 to $max-raw.
  */
  to-raw_ value/num lsb/float max-raw/int -> int:
    raw := (value / lsb).round
    if not 0 <= raw <= max-raw: throw "OUT_OF_RANGE"
    return raw

  /**
  Reads the given register with the supplied mask.

  Given that register reads are largely similar, implemented here. If the mask
   is left at 0xFFFF and offset at 0x0, it is treated as a read from the whole
   register.
  */
  read-register_ register/int --mask/int=0xFFFF --offset/int=(mask.count-trailing-zeros) -> any:
    raw-value := reg_.read-u16-be register
    if mask == 0xFFFF and offset == 0:
      return raw-value
    else:
      masked-value := (raw-value & mask) >> offset
      return masked-value

  /**
  Writes the given register with the supplied mask.

  Given that register writes are largely similar, it is implemented here.  If
   the mask is left at 0xFFFF and offset at 0x0, it is treated as a write to the
   whole register.
  */
  write-register_ register/int value/any --mask/int=0xFFFF --offset/int=(mask.count-trailing-zeros) -> none:
    // find allowed value range within field
    max/int := mask >> offset
    // check the value fits the field
    if (value & ~max) != 0: throw "OUT_OF_RANGE"

    if (mask == 0xFFFF) and (offset == 0):
      reg_.write-u16-be register value
    else:
      new-value/int := reg_.read-u16-be register
      new-value     &= ~mask
      new-value     |= (value << offset)
      reg_.write-u16-be register new-value

  /**
  Writes the STATUS register without clearing an alert flag by accident.

  The flag bits are cleared by writing 0 and are not affected by writing 1.  So
    all flags are written as 1, except those in $clear-flags.  A flag that is
    raised while this runs is therefore kept.  The bits in $mask are set to the
    corresponding bits of $value, and all other bits keep their value.
  */
  update-status_ --mask/int=0 --value/int=0 --clear-flags/int=0 -> none:
    current := read-status-raw
    new-value := (current & ~STATUS-ALL-ALERTS_ & ~mask)
        | (value & mask)
        | (STATUS-ALL-ALERTS_ & ~clear-flags)
    write-register_ REG-STATUS_ new-value
