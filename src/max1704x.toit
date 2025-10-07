
// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.   This file also includes derivative
// work from other authors and sources.  See accompanying documentation.
//
// Original IC Datasheet can be found at:
// https://www.analog.com/media/en/technical-documentation/data-sheets/MAX17048-MAX17049.pdf
//

import binary
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
  static STATUS-RESET-INDICATOR-MASK_  ::= 0b00000001_00000000  // Set when unconfigured, no model loaded.
  static STATUS-VOLTAGE-HIGH-MASK_     ::= 0b00000010_00000000  // V(cell) above ALRT.VALRTMAX.
  static STATUS-VOLTAGE-LOW-MASK_      ::= 0b00000100_00000000  // V(cell) below ALRT.VALRTMIN.
  static STATUS-VOLTAGE-RESET-MASK_    ::= 0b00001000_00000000  // Set if device has been reset (if EnVr is set).
  static STATUS-SOC-RATE-LOW-MASK_     ::= 0b00010000_00000000  // Set when SOC crosses the value in CONFIG.ATHD.
  static STATUS-SOC-CHANGE-MASK_       ::= 0b00100000_00000000  // Set when SOC changes by at least 1% (if CONFIG.ALSC is set)
  static VRESET-ALERT-ENABLE-MASK_     ::= 0b01000000_00000000  // Enable or Disable VRESET Alert

  static soc-rate-lsb_                 ::= 0.00390625    // 1% / 256  LSB
  static cell-voltage-lsb_             ::= 0.000078125   // 78.125 µV/LSB (i.e., 78.125e-6)
  static charge-rate-lsb-pct_          ::= 0.208         //  0.208% / LSB
  static hibernation-lsb-v_            ::= 0.00125       //  1.25mv / LSB
  static voltage-alert-lsb-v_          ::= 0.02          // 20mV / LSB
  static voltage-reset-lsb-v_          ::= 0.04          // 40mV    / LSB

  // For use with RCOMP tuning parameters
  static RCOMP0                        ::= 0x97
  static TEMP-COMPENSATION-UP          ::= -0.5
  static TEMP-COMPENSATION-DOWN        ::= -5.0

  // Class private variables
  reg_/registers.Registers := ?
  logger_/log.Logger := ?


  constructor dev/serial.Device --logger/log.Logger=log.default:
    logger_ = logger.with-name "max1704x"
    reg_ = dev.registers

  /**
  $reset:

  Writing a value of 0x5400 to this register causes the device to completely
   reset as if power had been removed (see the Power-On Reset (POR) section).
   The reset occurs when the last bit has been clocked in. The IC does not
   respond with an I2C ACK after this command sequence.
  */
  reset -> none:
    write-register_ REG-CMD_ POWER-ON-RESET-VALUE_
    sleep --ms=250

    clear-reset-indicator_
    if not get-reset-indicator_:
      logger_.debug "reset: waiting 1s for reset-indicator to clear..."
      clear-reset-indicator_
      sleep --ms=1100
      if not get-reset-indicator_:
        logger_.debug "reset: reset-indicator not cleared. Ignoring..."

  /**
  Returns True or False based on whether the Reset Indicator is tripped
  */
  get-reset-indicator_ -> bool:
    out := read-register_ REG-STATUS_ --mask=STATUS-RESET-INDICATOR-MASK_
    return (out == 1)

  /**
  Returns True or False based on whether the Reset Indicator is tripped
  */
  clear-reset-indicator_ -> none:
    write-register_ REG-STATUS_ 0 --mask=STATUS-RESET-INDICATOR-MASK_

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
  Sets Temperature Compensation in the IC.
  */
  set-temperature-compensation temperature/float=20.0 -> none:
    //old-rcomp := RCOMP0
    old-rcomp := get-rcomp-value
    new-rcomp := 0.0
    if (temperature > 20.0):
      new-rcomp = old-rcomp + (temperature - 20) * TEMP-COMPENSATION-UP
    else:
      new-rcomp = old-rcomp + (temperature - 20) * TEMP-COMPENSATION-DOWN


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
    assert: 0 < threshold < 32
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
    value := (enabled ? 1 : 0)
    write-register_ REG-MODE_ value --mask=MODE-SLEEP-ENABLED-MASK_

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
      logger_.error "sleep-now: Cannot sleep now as sleep mode not enabled."

  /**
  Set hibernation activity threshold. See README.md or Datasheet.
  */
  set-hibernation-act-threshold volts/float -> none:
    assert: 0 <= volts <= 0.31874
    value := volts / hibernation-lsb-v_
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
    assert: 0 <= percent <= 53
    value := (percent / charge-rate-lsb-pct_).round
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
    set-hibernation-act-threshold 0.0
    set-hibernation-hib-threshold 0.0

  /**
  Sets the hibernate mode to be forced on, with maximum settings:

  Datasheet states that setting both hibernation registers to maximum will
    'enable' hibernation.  The device will be configured t its maximum values.
    [See Datasheet pp.12]
  */
  set-hibernate-mode-enabled -> none:
    set-hibernation-act-threshold (0xFF).to-float
    set-hibernation-hib-threshold (0xFF).to-float

  /**
  Whether hibernate mode is enabled:

  */
  get-hibernate-mode-enabled -> bool:
    act-t := get-hibernation-act-threshold
    hib-t := get-hibernation-hib-threshold
    return (act-t > 0) and (hib-t > 0)

  /**
  Sets the Analog Comparator for Hibernation.  See README.md and Datasheet.
  */
  set-hibernate-analog-comparator-enabled enabled/bool=false -> none:
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
    value := (voltage / voltage-alert-lsb-v_).round
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
    value := (voltage / voltage-alert-lsb-v_).round
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

  get-vreset-alert-enabled -> bool:
    value := read-register_ REG-STATUS_ --mask=VRESET-ALERT-ENABLE-MASK_
    return value == 1

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
  Reads cell charge-rate - as % change per hour. (Not for conversion to amps).
  */
  read-cell-charge-rate -> float:
    raw/int := reg_.read-i16-be REG-CHARGE-RATE_
    return raw * charge-rate-lsb-pct_

  /**
  Reads the cell voltage (in Volts).
  */
  read-cell-voltage -> float:
    raw/int := read-register_ REG-CELL-VOLTAGE_
    return raw * cell-voltage-lsb_

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
  */
  is-ready -> bool:
    return get-chip-version != 0xFFFF

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
    write-register_ REG-MODE_ 1 --mask=MODE-QUICK-START-MODE-MASK_

  /**
  Sets the voltage the IC considers a 'reset'.  See README.md and/or Datasheet.
  */
  set-reset-voltage voltage/float -> none:
    assert: 0 <= voltage <= 5.0                    // raw values 0..127 for 7 bit register
    value := (voltage / voltage-reset-lsb-v_).round
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
  design-capacity-mah_ := 0
  design-capacity-wh_  := 0

  set-design-capacity-mah mah/float -> none:
    design-capacity-mah_ = mah

  set-design-capacity-wh wh/float -> none:
    design-capacity-wh_  = wh

  estimate-mah-remaining -> float:
    assert: design-capacity-mah_ > 0.0
    return (design-capacity-mah_ * (read-cell-state-of-charge) / 100.0)

  estimate-wh-remaining -> float:
    assert: design-capacity-wh_ > 0.0
    return (design-capacity-wh_ * (read-cell-state-of-charge) / 100.0)

  estimate-hours-left --charge-rate-pct/float=(read-cell-charge-rate) -> float:
    if charge-rate-pct >= -1e-6: return 1e9   // essentially "infinite" if not discharging
    return read-cell-state-of-charge / charge-rate-pct.abs

  /**
  If a current meter (such as INA226, INA219 or INA3221) can measure and provide
  the current of the battery, further information can also be derived.
  */
  estimate-hours-left --current-a/float -> float:
    assert: design-capacity-mah_ > 0.0
    return estimate-mah-remaining / (current-a.abs + 1e-6)

  estimate-expected-crate-pct_per_hr --current-a -> float:
    assert: design-capacity-mah_ > 0.0
    return (current-a / design-capacity-mah_) * 100.0

  estimate-effective-capacity-mah --current-a --charge-rate-pct/float=(read-cell-charge-rate)-> float:
    assert: design-capacity-mah_ > 0.0
    charge-rate := charge-rate-pct
    if charge-rate.abs < 0.05: return design-capacity-mah_     // ignore near-zero
    return ((current-a * 1000).abs * 100.0) / charge-rate.abs

  estimate-state-of-health --current-a -> float:
    assert: design-capacity-mah_ > 0.0
    return 100.0 * (estimate-effective-capacity-mah --current-a=current-a) / design-capacity-mah_

  estimate-hours-to-full --current-a/float -> float:
    state-of-charge := read-cell-state-of-charge
    if state-of-charge >= 99.9:
      return 0.0
    current-ma := (current-a * 1000)
    if current-ma <= 1e-6: return 1e9                     // not charging
    missing-mAh := design-capacity-mah_ * ((100.0 - state-of-charge) / 100.0)
    return (missing-mAh / current-ma) * 1.2               // 1.2 fudge for taper

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
    assert: ((value & ~max) == 0)

    if (mask == 0xFFFF) and (offset == 0):
      reg_.write-u16-be register (value & 0xFFFF)
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
