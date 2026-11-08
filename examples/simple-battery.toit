// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import max1704x show Max1704x

/**
Simple MAX1704x example.

Prints the battery voltage, state of charge and charge rate every two seconds.
  Only the MAX17048 (or MAX17049) is needed: no display or other sensors.

Wiring:
  - Place the battery into the JST connector on the MAX17048.
  - Connect VIN and GND of the MAX17048 to the 3v3 and GND on the ESP32.
  - Connect SDA and SCL of the MAX17048 to the pins below.
*/

// Pins for the DFRobot FireBeetle 2 ESP32-C6.  Change them for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

main:
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN

  if not bus.scan.contains Max1704x.I2C-ADDRESS:
    bus.close
    throw "No MAX1704x found at 0x$(%02x Max1704x.I2C-ADDRESS)"

  // Use '--variant=Max1704x.VARIANT-MAX17049' for the two-cell chip.
  driver := Max1704x (bus.device Max1704x.I2C-ADDRESS)

  if not driver.is-ready:
    bus.close
    throw "MAX1704x not ready.  Is a battery attached?"

  print "MAX1704x version $(driver.get-chip-version), id $(driver.get-chip-id)"

  while true:
    print "$(%0.3f driver.read-cell-voltage)v  $(%0.1f driver.read-cell-state-of-charge)%  $(%0.2f driver.read-cell-charge-rate)%/h"
    sleep --ms=2000
