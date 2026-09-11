# Getting Started From Zero

For a complete beginner with no EE experience and no boards/sensors purchased yet.

## Build path

**Stage 0 — Arduino fundamentals (~1-2 weeks, ~$30-40)**
Get an Arduino Uno-compatible starter kit (ELEGOO or the official Arduino kit both work) — it comes with a breadboard, jumper wires, resistors, LEDs, a potentiometer, and a project guidebook. Work through the basics: blink an LED, read a button, read a potentiometer with `analogRead()`, print values to the Serial Monitor. This is where breadboarding, digital vs analog I/O, sketch uploading, and reading serial output all get picked up — everything the real sensors depend on. Paul McWhorter's free "Arduino for absolute beginners" YouTube series is a well-regarded zero-experience starting point.

**Stage 1 — Voltage dividers (a few days)**
Practice reading a flex sensor or photoresistor through a simple voltage-divider circuit (sensor + fixed resistor in series, read the midpoint). This is the exact circuit the pneumograph needs later.

**Stage 2 — The two plug-and-play biosignal sensors**
- Pulse sensor (cardiosphygmograph): [Pulse Sensor Amped](https://www.adafruit.com/product/1093), ~$30. Plug-and-play — 3-pin cable straight into an analog pin, no soldering. Clips on a fingertip or earlobe.
- GSR sensor (galvanograph): [Grove GSR Sensor](https://www.seeedstudio.com/Grove-GSR-sensor-p-1614.html), ~$15-25. Two finger electrodes; wires go straight to 5V, GND, and an analog pin — no extra circuitry needed.

**Stage 3 — Pneumograph (respiration) — the DIY one**
No good off-the-shelf plug-and-play part exists for this channel. Standard approach: a [conductive stretch sensor](https://www.adafruit.com/product/519) worn as a chest band, wired into a voltage divider with a fixed resistor — as you inhale/exhale the band stretches, its resistance changes, and the divider's midpoint voltage tracks your breathing. Reference builds: Instructables' "DIY Breath Sensor with Arduino (Conductive Knitted Stretch Sensor)" and kobakant's breathing-belt writeup. Requires basic soldering / secure wiring.

**Stage 4 — Combine all three on one Arduino**
Wire pulse, GSR, and the stretch-sensor divider to three separate analog pins, verify each channel live using the Arduino IDE's Serial Plotter before writing any Mac code.

**Stage 5 — Mac software**
Once all three channels read cleanly, move to the SwiftUI app in `/mac-app`.

**Rough total budget:** ~$90-140 for all three sensor channels plus the starter kit.

## Safety note

Everything here stays low-voltage and USB/battery powered — the standard safe way to build hobbyist biosignal circuits. Don't combine this with mains-powered circuitry near the body. This is a recreational/educational project, not a medical device or a validated lie detector.
