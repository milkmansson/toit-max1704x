// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import max1704x show Max1704x

/**
Power modes example.

The MAX1704x has two low power modes:
  - Hibernation: the gauge slows its sampling.  It is entered and left
    automatically, depending on two thresholds.
  - Sleep: the gauge stops completely (below 1uA).  It is only entered when
    asked, and only after it has been enabled.
  See the README for the details of both, and for the warning about charging
  or discharging while asleep.
*/

// Pins for the DFRobot FireBeetle 2 ESP32-C6.  Change them for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

main:
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN
  driver := Max1704x (bus.device Max1704x.I2C-ADDRESS)
  if not driver.is-ready: throw "MAX1704x not ready.  Is a battery attached?"

  // Hibernation.
  print "Hibernate mode enabled: $driver.get-hibernate-mode-enabled"
  print "Enter hibernation below $(%0.3f driver.get-hibernation-hib-threshold)%/h"
  print "Leave hibernation above $(%0.4f driver.get-hibernation-act-threshold)v difference"
  print "Hibernating now: $driver.is-hibernating"

  // Hibernation is disabled by setting the thresholds to zero.  Either one does it.
  driver.set-hibernate-mode-disabled
  print "Hibernation disabled: enabled=$driver.get-hibernate-mode-enabled"

  // Set the thresholds again.  These are the power on defaults.
  driver.set-hibernation-hib-threshold 26.624
  driver.set-hibernation-act-threshold 0.06
  print "Hibernation restored: enabled=$driver.get-hibernate-mode-enabled"

  // Sleep.  Enable it first, or force-sleep-now is refused.
  driver.set-sleep-mode-enabled true
  print "Sleep mode enabled: $driver.get-sleep-mode-enabled"
  driver.force-sleep-now
  print "Asleep for 5 seconds..."
  sleep --ms=5000
  driver.force-wake-now
  print "Awake.  Cell voltage $(%0.3f driver.read-cell-voltage)v"

  driver.set-sleep-mode-enabled false
  bus.close
