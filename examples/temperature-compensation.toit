// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import max1704x show Max1704x

/**
Temperature compensation example.

The fuel gauge model is tuned with a value called RCOMP, which depends on the
  temperature of the battery.  The datasheet gives a formula, which the driver
  implements.  Update it when the temperature changes noticeably.

Use a real sensor (for example a BME280 near the battery) in battery-temperature.
*/

// Pins for the DFRobot FireBeetle 2 ESP32-C6.  Change them for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

// Replace with a reading from a temperature sensor.
battery-temperature -> float:
  return 25.0

main:
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN
  driver := Max1704x (bus.device Max1704x.I2C-ADDRESS)
  if not driver.is-ready: throw "MAX1704x not ready.  Is a battery attached?"

  print "RCOMP at power on: 0x$(%02x driver.get-rcomp-value)"

  // What the formula gives at a few temperatures.
  [-10.0, 0.0, 20.0, 25.0, 40.0].do: | temperature/float |
    print "  $(%5.1f temperature)C -> 0x$(%02x Max1704x.calculate-rcomp temperature)"

  while true:
    temperature := battery-temperature
    driver.set-temperature-compensation temperature
    print "Battery at $(%0.1f temperature)C: RCOMP set to 0x$(%02x driver.get-rcomp-value), $(%0.1f driver.read-cell-state-of-charge)%"
    sleep --ms=10_000
