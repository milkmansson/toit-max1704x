// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import max1704x show Max1704x

/**
Capacity and run time estimates.

The MAX1704x measures voltage and state of charge, but not current.  Given the
  design capacity of the battery, the driver estimates the remaining energy and
  run time.  These are estimates: batteries age, and the numbers change with
  temperature and load.  The state of health is only meaningful while the real
  load is close to LOAD-CURRENT-A and the battery is clearly charging or
  discharging.

If a current meter (such as an INA219 or INA226) is available, use its reading
  in place of LOAD-CURRENT-A below.
*/

// Pins for the DFRobot FireBeetle 2 ESP32-C6.  Change them for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

// The battery.
DESIGN-CAPACITY-MAH ::= 3700
DESIGN-CAPACITY-WH ::= 13.7

// The current drawn from the battery, in amps.  Set it to what your circuit
// draws, or take it from a current meter.
LOAD-CURRENT-A ::= 0.04

// The slowest charge rate, in %/h, to estimate the state of health from.
MIN-RATE-FOR-HEALTH ::= 2.0

main:
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN
  driver := Max1704x (bus.device Max1704x.I2C-ADDRESS)
  if not driver.is-ready: throw "MAX1704x not ready.  Is a battery attached?"

  driver.set-design-capacity-mah DESIGN-CAPACITY-MAH
  driver.set-design-capacity-wh DESIGN-CAPACITY-WH

  while true:
    soc := driver.read-cell-state-of-charge
    rate := driver.read-cell-charge-rate
    print "$(%0.3f driver.read-cell-voltage)v  $(%0.1f soc)%  $(%0.2f rate)%/h"
    print "  remaining: $(%0.0f driver.estimate-mah-remaining) mAh, $(%0.2f driver.estimate-wh-remaining) Wh"
    print "  hours left at $(LOAD-CURRENT-A)A: $(%0.1f driver.estimate-hours-left --current-a=LOAD-CURRENT-A)"
    print "  hours left at the measured charge rate: $(%0.1f driver.estimate-hours-left)"
    print "  the load should cause $(%0.2f driver.estimate-expected-charge-rate --current-a=LOAD-CURRENT-A)%/h, measured $(%0.2f rate)%/h"
    // The charge rate has a resolution of 0.208%/h, so it must be well above that to be useful.
    if rate.abs < MIN-RATE-FOR-HEALTH:
      print "  state of health: needs charging or discharging faster than $(MIN-RATE-FOR-HEALTH)%/h"
    else:
      health := driver.estimate-state-of-health --current-a=LOAD-CURRENT-A
      print "  state of health: $(health ? "$(%0.0f health)%" : "unknown")"
    sleep --ms=5000
