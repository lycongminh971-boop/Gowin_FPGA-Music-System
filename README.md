# 🎵 Gowin FPGA Music System

**xinqin——An FPGA-based Real-Time Polyphonic Music Synthesis System**

芯琴——基于 FPGA 的实时多音色复音合成电子乐器系统。

[![FPGA](https://img.shields.io/badge/FPGA-Gowin-blue)](https://www.gowinsemi.com/)
[![HDL](https://img.shields.io/badge/HDL-Verilog-orange)](https://en.wikipedia.org/wiki/Verilog)
[![Platform](https://img.shields.io/badge/Platform-Tang--Mega--60K-green)](https://www.gowinsemi.com/)
[![Status](https://img.shields.io/badge/Status-Under%20Development-yellow)]()

---

## 1. Introduction

Gowin FPGA Music System is a real-time polyphonic music synthesis project based on the Gowin FPGA platform.

The project aims to implement a hardware-based digital audio synthesis engine using Verilog HDL. It supports multi-voice sound generation, real-time note control, and digital audio output.

Unlike traditional software-based synthesizers, the core audio processing pipeline is implemented directly in FPGA programmable logic (PL), providing deterministic processing latency and parallel signal processing capabilities.

The system is designed to explore FPGA-based digital audio processing, real-time music synthesis, and hardware-software interaction.

## 2. Key Features

### Audio Synthesis
- Real-time digital audio synthesis.
- Multi-voice polyphonic sound generation.
- DDS-based waveform generation.
- ROM-based waveform lookup.
- ADSR envelope generation.
- Digital audio output through I2S.

### Input and Control
- Capacitive touch sensing.
- MPR121 touch controller interface.
- I2C communication implemented in Verilog.
- Real-time note triggering and release.
- Android BLE control interface (planned / under development).

### FPGA Implementation
- Parallel hardware processing.
- Hardware-based audio signal generation.
- Low-latency audio processing.
- Resource-conscious FPGA design.

## 3. System Architecture

The planned system architecture is divided into several functional modules:

```text
          Input / Control
                 |
       +---------+---------+
       |                   |
  Capacitive Touch     Android BLE
       |                   |
       +---------+---------+
                 |
          Control Logic
                 |
          Voice Manager
                 |
       +---------+---------+
       |         |         |
     Voice 1   Voice 2   Voice N
       |         |         |
      DDS       DDS       DDS
       |         |         |
     ADSR      ADSR      ADSR
       |         |         |
       +---------+---------+
                 |
           Audio Mixer
                 |
            I2S Output
                 |
             Audio DAC
                 |
          Audio Amplifier
                 |
           Headphone Output
```

## 4. Hardware Platform

| Component | Description |
|---|---|
| FPGA Board | Tang-Mega-60K |
| FPGA Device | GW5AT-LV60 |
| Audio DAC | PTB211-S |
| Audio Amplifier | N54263 |
| Touch Controller | MPR121 |
| Communication | I2C / BLE |
| Audio Interface | I2S |

## 5. Development Environment

| Tool | Purpose |
|---|---|
| Gowin EDA | FPGA design and implementation |
| Verilog HDL | Hardware description |
| ModelSim | RTL simulation |
| Git | Version control |
| Android Studio | Android application development |

## 6. Project Structure

```text
Gowin_FPGA-Music-System/
│
├── src/                    # Verilog source files
│   ├── top.v
│   ├── dds.v
│   ├── adsr.v
│   ├── i2s.v
│   └── ...
│
├── sim/                    # Simulation files
│
├── android/                # Android application
│
├── impl/                   # FPGA implementation files
│
├── data/                   # Waveform and configuration data
│
├── deliverables/           # Project documentation and outputs
│
├── art.gprj                # Gowin project file
├── .gitignore
└── README.md
```

*Note: The directory structure above describes the intended organization. Adjust filenames and folders to match the actual repository.*

## 7. Development Progress

The project is currently under development.

| Module | Status |
|---|---|
| FPGA project setup | In progress / verify |
| DDS waveform generation | In progress |
| ROM waveform storage | In progress |
| ADSR envelope | In progress |
| Polyphonic voice management | In progress |
| Audio mixing | In progress |
| I2S audio output | In progress |
| MPR121 I2C communication | In progress |
| Touch input processing | In progress |
| Android BLE control | Planned / in progress |
| System integration | Planned |

## 8. Roadmap

- [ ] Complete the basic DDS audio generation module.
- [ ] Implement a stable ADSR envelope generator.
- [ ] Expand the system to support at least four independent voices.
- [ ] Implement real-time polyphonic mixing.
- [ ] Complete I2S audio output.
- [ ] Improve capacitive touch input stability.
- [ ] Integrate Android BLE control.
- [ ] Optimize FPGA resource utilization and timing.
- [ ] Complete end-to-end system testing.

## 9. Design Goals

The project focuses on the following engineering objectives:

- **Real-time performance:** Minimize the latency between user input and audio output.
- **Hardware parallelism:** Use FPGA parallel processing to implement independent synthesis voices.
- **Modularity:** Separate audio generation, envelope control, mixing, and communication modules.
- **Scalability:** Support additional voices and synthesis methods.
- **Resource optimization:** Balance audio quality, logic utilization, and timing performance.

## 10. Author

**Author:** Cong Minh Ly

**Repository:** [Gowin_FPGA-Music-System](https://github.com/lycongminh971-boop/Gowin_FPGA-Music-System)

---

*This project is developed for FPGA-based real-time digital audio synthesis and electronic musical instrument design.*
