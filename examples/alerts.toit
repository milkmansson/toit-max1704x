// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import max1704x show Max1704x

/**
Alerts example.

The MAX1704x raises an alert when the battery crosses a threshold: it sets a
  flag in the STATUS register and pulls the ALRT pin low.  This example sets
  the thresholds, then deliberately trips the high voltage alert so that you
  can see the flags and how to clear them.

Wiring:
  - As for simple-battery.toit.  To react to the ALRT pin instead of polling,
    connect it to a GPIO and wait for it to go low.
*/

// Pins for the DFRobot FireBeetle 2 ESP32-C6.  Change them for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

main:
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN
  driver := Max1704x (bus.device Max1704x.I2C-ADDRESS)
  if not driver.is-ready: throw "MAX1704x not ready.  Is a battery attached?"

  // Alert when the state of charge falls to 10%, or the voltage leaves 3.3v - 4.25v.
  driver.set-soc-empty-alert-threshold 10
  driver.set-voltage-alert-min 3.3
  driver.set-voltage-alert-max 4.25
  // Also alert whenever the state of charge changes by 1%.
  driver.set-soc-change-alert-enabled true

  // Clear anything raised before the thresholds were set (the reset indicator is set at power on).
  driver.clear-status-flags Max1704x.STATUS-RESET-INDICATOR
  driver.clear-alert
  print "Alert thresholds set.  Alert active: $driver.alert"

  // Trip the high voltage alert on purpose: set the maximum just under the present voltage.
  voltage := driver.read-cell-voltage
  driver.set-voltage-alert-max (voltage - 0.1)
  sleep --ms=1500  // The IC updates its flags as it samples.
  print "Cell voltage $(%0.3f voltage)v, high alert at $(%0.2f driver.get-voltage-alert-max)v"
  print "Alert active: $driver.alert"
  print "Voltage high flag: $(driver.check-status Max1704x.STATUS-VOLTAGE-HIGH)"
  print "Status register: 0x$(%04x driver.read-status-raw)"

  // Acknowledge.  Put the threshold back first: while the condition is still
  // true the IC raises the flag again at its next sample.  Then clear the flag,
  // and release the ALRT pin.
  driver.set-voltage-alert-max 4.25
  sleep --ms=1500
  driver.clear-status-flags Max1704x.STATUS-VOLTAGE-HIGH
  driver.clear-alert
  print "After clearing, alert active: $driver.alert, voltage high flag: $(driver.check-status Max1704x.STATUS-VOLTAGE-HIGH)"

  bus.close
