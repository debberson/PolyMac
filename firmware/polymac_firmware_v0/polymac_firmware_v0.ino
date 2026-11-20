// PolyMac firmware v0 - three-channel sampler
// Channels: A0 = respiration (stretch cord divider), A1 = pulse, A2 = GSR
// 100 Hz fixed-rate sampling, 115200 baud.

const uint8_t PIN_RESP = A0;
const uint8_t PIN_PULSE = A1;
const uint8_t PIN_GSR = A2;

const unsigned long SAMPLE_INTERVAL_US = 10000;  // 100 Hz

// true  = labeled output for the Arduino IDE Serial Plotter (use this first)
// false = CSV "timestamp_ms,resp,pulse,gsr" for the Mac app
const bool PLOTTER_MODE = true;

unsigned long nextSampleUs;

void setup() {
  Serial.begin(115200);
  nextSampleUs = micros() + SAMPLE_INTERVAL_US;
}

void loop() {
  unsigned long now = micros();
  if ((long)(now - nextSampleUs) < 0) return;
  nextSampleUs += SAMPLE_INTERVAL_US;

  int resp = analogRead(PIN_RESP);
  int pulse = analogRead(PIN_PULSE);
  int gsr = analogRead(PIN_GSR);

  if (PLOTTER_MODE) {
    Serial.print("resp:");
    Serial.print(resp);
    Serial.print(",pulse:");
    Serial.print(pulse);
    Serial.print(",gsr:");
    Serial.println(gsr);
  } else {
    Serial.print(millis());
    Serial.print(',');
    Serial.print(resp);
    Serial.print(',');
    Serial.print(pulse);
    Serial.print(',');
    Serial.println(gsr);
  }
}
