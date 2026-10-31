
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

/** Toit Driver library for MAX17048/MAX17049 ICs */

class Max1704x:

  static I2C-ADDRESS                   ::= 0x36   // Not configurable

  // Datasheet page 11.
  static REG-CONFIG_                   ::= 0x0C   // Configuration register
  static REG-STATUS_                   ::= 0x1A   // Current alert/status
  static REG_MODE_                     ::= 0x06   // Mode register

  static REG-SOC_                      ::= 0x04   // Cell state of charge register
  static REG-CELL-VOLTAGE_             ::= 0x02   // Cell voltage register
  static REG-CHARGE-RATE_              ::= 0x16   // Cell charge rate register

  static REG-VOLTAGE-RESET-ID_         ::= 0x18   // Reset voltage settings (and ID) register
  static REG-VOLTAGE-ALERT_            ::= 0x14   // Voltage alert values register

  static REG_HIBERNATE_                ::= 0x0A   // Hibernation configuration register
  static REG_VERSION_                  ::= 0x08   // Holds IC version

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

  // For use with $REG-HIBERNATE-
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
  $reset:

  Writing a value of 0x5400 to this register causes the device to completely
   reset as if power had been removed (see the Power-On Reset (POR) section).
   The reset occurs when the last bit has been clocked in. The IC does not
   respond with an I2C ACK after this command sequence.

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

  /**
  Returns True or False based on whether the Reset Indicator is tripped
  */
  get-reset-indicator_ -> bool:
    out := read-register_ REG-STATUS_ --mask=STATUS-RESET-INDICATOR
    return (out == 1)

  /**
  Clears the Reset Indicator.
  */
  clear-reset-indicator_ -> none:
    write-register_ REG-STATUS_ 0 --mask=STATUS-RESET-INDICATOR

  /**
  Gets Chip Version.  Indicates the production version of the IC
  */
  get-chip-version -> int:
    out := read-register_ REG-VERSION_
    //logger_.debug "get-ic-version: returned $(bits-16 out) [0x$(%04x out)]"
    return out

  /**
  Gets Chip ID. (Datasheet pp13).

  Value that is one-time program-mable at the factory, which can be used as
   an identifier to distinguish multiple cell types in production.
  */
  get-chip-id -> int:
    out := read-register_ REG-VOLTAGE-RESET-ID_ --mask=CHIP-ID-MASK_
    //logger_.debug "get-ic-version: returned $(bits-16 out)"
    return out

  /**
  Gets RCOMP values from the IC. (See Datasheet and README.md)
  */
  get-rcomp-value -> int:
    out := read-register_ REG-CONFIG_ --mask=CHEMISTRY-RCOMP-MASK_
    logger_.debug "get-rcomp-value: returned $(%04x out)"
    return out

  /**
  Sets RCOMP values in the IC. (See Datasheet and README.md)
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

  When this bit is set, the ALRT pin asserts (is low). Use clear-alert to de-assert
   the ALRT pin. The STATUS register specifies why the ALRT pin was asserted
  */
  alert -> bool:
    out := read-register_ REG-CONFIG_ --mask=ALERT-MASK_
    return out == 1

  /**
  Clears an alert by the IC when an alert occurs.
  */
  clear-alert -> none:
    write-register_ REG-CONFIG_ 0 --mask=ALERT-MASK_

  /**
  Sets the 'SOC is empty now' alert threshold.  See README.md
  */
  set-SOC-empty-alert-threshold threshold/int -> none:
    if not 1 <= threshold <= 32: throw "OUT_OF_RANGE"
    write-register_  REG-CONFIG_ (32 - threshold) --mask=EMPTY-ALERT-THRESHOLD-MASK_

  /**
  Gets the 'SOC is empty now' alert threshold.  See README.md
  */
  get-SOC-empty-alert-threshold -> int:
    out := read-register_ REG-CONFIG_ --mask=EMPTY-ALERT-THRESHOLD-MASK_
    return (32 - out)

  /**
  Enable the ability to enter ultra-low-power sleep mode.

  Use True to enable sleep mode (1uA draw) - False to only allow hibernation
  */
  set-sleep-mode-enabled enabled/bool=false -> none:
    // MODE is a write-only register (apart from HibStat), so it is written
    // whole rather than read-modified-written.  This way a stale Quick-Start
    // bit can never be written back, which would trigger another quick-start.
    write-register_ REG-MODE_ (enabled ? MODE-SLEEP-ENABLED-MASK_ : 0)

  /**
  Whether the device has the ability to enter ultra-low-power sleep mode.

  Use True to enable sleep mode (1uA draw) - False to only allow hibernation
  */
  get-sleep-mode-enabled -> bool:
    value := read-register_ REG-MODE_ --mask=MODE-SLEEP-ENABLED-MASK_
    return (value == 1)

  /**
  Sleeps the device - Forces device into sleep mode - now.

  Requires Sleep Mode be enabled beforehand.
  */
  force-sleep-now -> none:
    if get-sleep-mode-enabled:
      write-register_ REG-CONFIG_ 1 --mask=SLEEP-MASK_
    else:
      logger_.error "sleep-now: Cannot sleep now as sleep mode not enabled."

  /**
  Wakes the device - forces device out of sleep mode - now.

  Requires Sleep Mode be enabled beforehand.
  */
  force-wake-now -> none:
    if get-sleep-mode-enabled:
      write-register_ REG-CONFIG_ 0 --mask=SLEEP-MASK_
    else:
      logger_.error "wake-now: Cannot wake now as sleep mode not enabled."

  /**
  Set hibernation activity threshold. See README.md or Datasheet.
  */
  set-hibernation-act-threshold volts/float -> none:
    value := to-raw_ volts hibernation-lsb-v_ 0xFF
    write-register_ REG_HIBERNATE_ value --mask=HIBERNATE-ACT-THRESHOLD-MASK_

  /**
  Get hibernation activity threshold. See README.md or Datasheet.
  */
  get-hibernation-act-threshold -> float:
    value := read-register_ REG_HIBERNATE_ --mask=HIBERNATE-ACT-THRESHOLD-MASK_
    return value * hibernation-lsb-v_

  /**
  Sets hibernate threshold: the %/hour change triggering hibernation of the IC.
  */
  set-hibernation-hib-threshold percent/float -> none:
    value := to-raw_ percent charge-rate-lsb-pct_ 0xFF
    write-register_ REG_HIBERNATE_ value --mask=HIBERNATE-HIB-THRESHOLD-MASK_

  /**
  Gets hibernate threshold: the %/hour change triggering hibernation of the IC.
  */
  get-hibernation-hib-threshold -> float:
    value := read-register_ REG_HIBERNATE_ --mask=HIBERNATE-HIB-THRESHOLD-MASK_
    return value * charge-rate-lsb-pct_

  /**
  Sets the hibernate mode to be disabled:

  Datasheet states that setting the registers to = 0x0000 disables hibernation.
  To always use hibernate mode, set entire register = 0xFFFF. [See Datasheet pp.12]
  */
  set-hibernate-mode-disabled -> none:
    write-register_ REG_HIBERNATE_ 0x0000

  /**
  Sets the hibernate mode to be forced on, with maximum settings:

  Datasheet states that setting both hibernation registers to maximum will
    'enable' hibernation.  The device will be configured t its maximum values.
    [See Datasheet pp.12]
  */
  set-hibernate-mode-enabled -> none:
    write-register_ REG_HIBERNATE_ 0xFFFF

  /**
  Whether hibernate mode is enabled.

  Hibernation is disabled if either threshold is zero.
  */
  get-hibernate-mode-enabled -> bool:
    act-t := get-hibernation-act-threshold
    hib-t := get-hibernation-hib-threshold
    return (act-t > 0) and (hib-t > 0)

  /**
  Sets the Analog Comparator for Hibernation.  See README.md and Datasheet.
  */
  set-hibernate-analog-comparator-enabled enabled/bool=true -> none:
    value := enabled ? 0 : 1
    write-register_ REG-VOLTAGE-RESET-ID_ value --mask=HIBERNATE-DIS-ANALOG-CO-MASK_

  /**
  Get Analog Comparator setting for Hibernation.  See README.md and Datasheet.
  */
  get-hibernate-analog-comparator-enabled -> bool:
    value := read-register_ REG-VOLTAGE-RESET-ID_ --mask=HIBERNATE-DIS-ANALOG-CO-MASK_
    return value == 0

  /**
  Sets alert-min voltage - Alerts when V(cell) < V(alert-min).
  */
  set-voltage-alert-min voltage/float -> none:
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
  set-voltage-alert-max voltage/float -> none:
    value := to-raw_ voltage voltage-alert-lsb-v_ 0xFF
    write-register_ REG-VOLTAGE-ALERT_ value --mask=ALERT-VOLTAGE-MAX-MASK_

  /**
  Returns configured alert-max voltage.
  */
  get-voltage-alert-max -> float:
    value := read-register_ REG-VOLTAGE-ALERT_ --mask=ALERT-VOLTAGE-MAX-MASK_
    return value * voltage-alert-lsb-v_

  /**
  Enables voltage reset alert.

  When set, asserts the ALRT pin when a voltage-reset event occurs under the
  conditions described by the VRESET/ ID register.
  */
  set-vreset-alert-enabled enabled/bool=false -> none:
    value := (enabled ? 1 : 0)
    write-register_ REG-STATUS_ value --mask=VRESET-ALERT-ENABLE-MASK_

  /** Whether the voltage reset alert is enabled. */
  get-vreset-alert-enabled -> bool:
    value := read-register_ REG-STATUS_ --mask=VRESET-ALERT-ENABLE-MASK_
    return value == 1

  /**
  Enables the alert when the state of charge changes by at least 1%.

  The change is reported with $STATUS-SOC-CHANGE, and asserts the ALRT pin.
  */
  set-soc-change-alert-enabled enabled/bool=false -> none:
    write-register_ REG-CONFIG_ (enabled ? 1 : 0) --mask=ALERT-SOC-CHANGE-MASK_

  /** Whether the state-of-charge change alert is enabled. */
  get-soc-change-alert-enabled -> bool:
    return (read-register_ REG-CONFIG_ --mask=ALERT-SOC-CHANGE-MASK_) == 1

  /**
  $check-status: checks a status flag against the current alert register.

  Returns true or false if the specified alert is set. (STATUS-*** statics above)
  */
  check-status alert/int -> bool:
    return (read-status-raw & alert) != 0

  /**
  Reads the raw status value register (also useful for troubleshooting)
  */
  read-status-raw -> int:
    value := read-register_ REG-STATUS_
    return value

  /**
  Clears the given status $flags (one or more of the STATUS-* statics).

  Flags are cleared by writing zero.  Other bits, including the voltage reset
    alert enable, are left as they were.
  */
  clear-status-flags flags/int -> none:
    if flags & ~STATUS-ALL-ALERTS_ != 0: throw "INVALID_ARGUMENT"
    write-register_ REG-STATUS_ ((read-status-raw) & ~flags)

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

  Use with caution.  See README.md, and Datasheet page 9.
  */
  set-quickstart -> none:
    // See $set-sleep-mode-enabled: MODE is written whole.  Keep the sleep setting.
    sleep-bit := get-sleep-mode-enabled ? MODE-SLEEP-ENABLED-MASK_ : 0
    write-register_ REG-MODE_ (MODE-QUICK-START-MODE-MASK_ | sleep-bit)

  /**
  Sets the voltage the IC considers a 'reset'.  See README.md and/or Datasheet.

  The datasheet guarantees the 2.28V to 3.48V range, in 40mV steps.
  */
  set-reset-voltage voltage/float -> none:
    value := to-raw_ voltage voltage-reset-lsb-v_ 0x7F   // 7 bit field
    write-register_ REG-VOLTAGE-RESET-ID_ value --mask=VRESET-MASK_

  /**
  Gets the voltage the IC considers a 'reset'.  See README.md and/or Datasheet.
  */
  get-reset-voltage -> float:
    value := read-register_ REG-VOLTAGE-RESET-ID_ --mask=VRESET-MASK_
    return (value * voltage-reset-lsb-v_)

  /**
  NOT YET IMPLEMENTED: TABLE Registers (0x40 to 0x7F)
  Datasheets require contact with Maxim for details on how to configure these
  registers. The default value is appropriate for some Li+ batteries.

  To unlock the TABLE registers, write 0x57 to address 0x3F, and 0x4A to
  address 0x3E. While TABLE is unlocked, no ModelGauge registers are updated,
  so relock as soon as possible by writing 0x00 to address 0x3F, and 0x00 to
  address 0x3E.
  */

  /** EXPERIMENTAL

  The following functions are created somewhat experimentally.  The health and
  actual capacities of batteries change over time, as well as actual values
  varying by things like temperature and stress.  Please consider these
  experimental in nature.

  Given the design-capacity-mah_ and design-capacity-wh_, several other pieces
  of information can be derived.
  */
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
  estimate-expected-crate-pct_per_hr --current-a/num -> float:
    if design-capacity-mah_ <= 0.0: throw "design capacity (mAh) not set"
    return (current-a * 1000.0 / design-capacity-mah_) * 100.0

  /**
  Estimates the effective capacity (in mAh) from the present current (in amps)
    and charge rate (in %/hour).

  Returns null if the charge rate is too close to zero for a meaningful result.
  */
  estimate-effective-capacity-mah --current-a/num --charge-rate-pct/float=(read-cell-charge-rate) -> float?:
    if design-capacity-mah_ <= 0.0: throw "design capacity (mAh) not set"
    if charge-rate-pct.abs < 0.05: return null    // Too small to be reliable.
    return (current-a * 1000.0).abs * 100.0 / charge-rate-pct.abs

  /**
  Estimates the state of health (in %): effective capacity vs design capacity.

  Returns null if it cannot be determined, see $estimate-effective-capacity-mah.
  */
  estimate-state-of-health --current-a/num -> float?:
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
  Display bitmasks nicely - useful when testing.
  */
  bits-16 x/int --min-display-bits/int=0 -> string:
    if (x > 255) or (min-display-bits > 8):
      out-string := "$(%b x)"
      out-string = out-string.pad --left 16 '0'
      out-string = "$(out-string[0..4]).$(out-string[4..8]).$(out-string[8..12]).$(out-string[12..16])"
      return out-string
    else if (x > 15) or (min-display-bits > 4):
      out-string := "$(%b x)"
      out-string = out-string.pad --left 8 '0'
      out-string = "$(out-string[0..4]).$(out-string[4..8])"
      return out-string
    else:
      out-string := "$(%b x)"
      out-string = out-string.pad --left 4 '0'
      out-string = "$(out-string[0..4])"
      return out-string
