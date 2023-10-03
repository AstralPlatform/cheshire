# Xilinx FGPAs

This page describes how to map Cheshire on Xilinx FPGAs to *execute baremetal programs* or *boot CVA6 Linux*. Please first read [Getting Started](../gs.md) to make sure have all dependencies and built the hardware, software, and Xilinx FPGA scripts. Additionally, for on-chip debugging you need:

- OpenOCD `>= 0.10.0`

We currently provide working setups for:

- Digilent Genesys 2 with Vivado `>= 2020.2`
- Xilinx VCU128 with Vivado `>= 2020.2`

We are working on support for more boards in the future.

## Implementation

Since the implementation steps and available features vary between boards, we provide instructions and document available features for each.

### Digilent Genesys 2

Generate the bitstream `target/xilinx/out/cheshire_top_xilinx.bit` by running:

```
make chs-xil-all BOARD=genesys2 MODE=[batch,gui]
```

See the argument list below:

* `VIVADO`: The Vivado version to use (see default in `target/xilinx/xilinx.mk`)
* `MODE`: If 'batch', compile in shell, if 'gui', Open Vivado GUI.

Before flashing the bitstream to your device, take note of the position of onboard switches, which control important functionality:


  | Switch | Function                                        |
  | ------ | ------------------------------------------------|
  | 1 .. 0 | Boot mode; see [Boot ROM](../um/sw.md#boot-rom) |
  | 5 .. 2 | Fan level; *do not* keep at 0                   |
  | 7      | Test mode; *leave at zero*                      |

The reset, JTAG TAP, UART, I2C, and VGA are all connected to their onboard logic or ports. The UART has *no flow control*. The microSD slot is connected to chip select 0 of the SPI host peripheral. Serial link and GPIOs are currently not available.

### Xilinx VCU128

Generate the bitstream `target/xilinx/out/cheshire_top_xilinx.bit` by running:

```
make chs-xil-all BOARD=vcu128 MODE=[batch,gui] INT-JTAG=[0,1]
```

See the argument list below:

* `INT-JTAG`: If 1, use an external JTAG chain (we use a Digilent JTAG-HS2 cable connected to the Xilinx XM105 FMC debug card). See the connections in `vcu128.xdc`.


As there are no switches on this board, the bootmode is selected by VIO (see next section).

## Using the Vivado GUI

Even after implementing your system in batch mode, you can open the Vivado GUI with:

```
make chs-xil-gui
```

In particular, it will give you access the to Virtual Inputs Outputs (VIOs) after flashing/refreshing the FPGA:

  | VIO               | Function                                                        |
  | ----------------- | ----------------------------------------------------------------|
  | vio_reset         | Positive edge-sensitive reset for the whole system              |
  | vio_boot_mode     | Override the boot-mode switches described above                 |
  | vio_boot_mode_sel | Select between 0: using boot mode switches 1: use boot mode VIO |

## Debugging with OpenOCD

To establish a debug bridge over JTAG, ensure the target is in a debuggable state (for example by resetting into the idle boot mode 0) and launch OpenOCD with:

```
openocd -f $(bender path ariane)/corev_apu/fpga/ariane.cfg
```

In another shell, launch a RISC-V GDB session attaching to OpenOCD:

```
riscv64-unknown-elf-gdb -ex "target extended-remote localhost:3333"
```

You can now interrupt (Ctrl+C), inspect, and repoint execution with GDB as usual. Note that resetting the board during debug sessions is not supported. If the debug session dies or you need to reset the board for another reason:

1. Terminate GDB and OpenOCD
2. Reset the board
3. Relaunch OpenOCD, then GDB.

## Running Baremetal Code

Baremetal code can be preloaded through JTAG using OpenOCD and GDB or loaded from an SD Card. In principle, other interfaces may also be used to boot if the board provides them, but no setups are available for this.

First, connect to UART using a serial communication program like minicom:

```
minicom -cD /dev/ttyUSBX
```

Make sure that hardware flow control matches your board's setup (usually *off*).

In the following examples, we will use the `helloworld` test. As in simulation, you can replace this with any baremetal program of your choosing or design; see [Baremetal Programs](../um/sw.md#baremetal-programs).

### JTAG Preloading

Start a debug session in the project root and enter in GDB:

```
load sw/tests/helloworld.spm.elf
continue
```

You should see `Hello World!` output printed on the UART.

### Boot from SD Card

First, build an up-to-date a disk image for your desired binary. For `helloworld`:

```
make sw/tests/helloworld.gpt.bin
```

Then flash this image to an SD card (for Genesys2) (*note that this requires root privileges*):

```
sudo dd if=sw/tests/helloworld.gpt.bin of=/dev/<sdcard>
sudo sgdisk -e /dev/<sdcard>
```

The second command only ensures correctness of the partition layout; it moves the secondary GPT header at the end of the minimally sized image to the end of your actual SD card.

Insert your SD card and reset into boot mode 1. You should see a `Hello World!` UART output.

## Booting Linux

To boot Linux, we must load the *OpenSBI* firmware, which takes over M mode and launches the U-boot bootloader. U-boot then loads Linux. For more details, see [Boot Flow](../um/sw.md#boot-flow).

Clone the `cheshire` branch of CVA6 SDK and build the firmware (OpenSBI + U-boot) and Linux images (*this will take about 30 minutes*):

```
git submodule update --init --recursive sw/deps/cva6-sdk
make -C sw/deps/cva6-sdk images
```

In principle, we can boot Linux through JTAG by loading all images into memory, launching OpenSBI, and instructing U-boot to load the kernel directly from memory. Here, we focus on autonomous boot from SD card.

In this case, OpenSBI is loaded by a regular baremetal program called the [Zero-Stage Loader](../um/sw.md#zero-stage-loader) (ZSL). The [boot ROM](../um/sw.md#boot-rom) loads the ZSL from SD card, which then loads the device tree and firmware from other SD card partitions into memory and launches OpenSBI.

To create a full Linux disk image from the ZSL, device tree, firmware, and Linux, run:

```
# Note that the device tree depends from the board's peripherals
make chs-linux-img BOARD=[genesys2, vcu128]
```

### Digilent Genesys 2

Flash this image to an SD card as you did in the previous section, then insert the SD card and reset into boot mode 1. You should first see the ZSL print on the UART:

```
 /\___/\       Boot mode:       1
( o   o )      Real-time clock: ... Hz
(  =^=  )      System clock:    ... Hz
(        )     Read global ptr: 0x...
(    P    )    Read pointer:    0x...
(  U # L   )   Read argument:   0x...
(    P      )
(           ))))))))))
```
You should then boot through OpenSBI, U-Boot, and Linux until you are dropped into a shell.

### Xilinx VCU128

This board does not offer a SD card reader. We use the integrated flash:

```
make chs-xil-flash MODE=batch BOARD=vcu128
```

Use the following parameters (defaults are in `target/xilinx/xilinx.mk`) to select your board:

* XILINX_PART  : The FPGA part (leave to default)
* XILINX_BOARD : The FPGA board (leave to default)
* XILINX_HOST  : The server where your board is connected (or localhost)
* XILINX_PORT  : The port opened by Vivado for your board (Vivado usually sets it to 3121)
* VIVADO_PATH  : The path to your board as seen in the Vivado Hardware Manager (usually xilinx_tcf/Xilinx/`SerialID`)
