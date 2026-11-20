# firmware

Arduino sketches live here: sensor sampling (pulse, GSR, respiration) on fixed-rate analog reads, packed as CSV lines and streamed over USB serial to the Mac app.

`polymac_firmware_v0/` samples A0 (respiration), A1 (pulse) and A2 (GSR) at 100 Hz and prints them at 115200 baud. Set `PLOTTER_MODE` to `true` for the Arduino IDE Serial Plotter or `false` for CSV (`timestamp_ms,resp,pulse,gsr`); the Mac app reads either.
