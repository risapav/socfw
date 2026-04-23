from socfw.config.ip_loader import IpLoader


def test_load_ip_with_bus_interfaces(tmp_path):
    fp = tmp_path / "axi_gpio.ip.yaml"
    fp.write_text(
        """
version: 2
kind: ip
ip:
  name: axi_gpio
  module: axi_gpio
  category: peripheral
origin:
  kind: source
  packaging: plain_rtl
integration:
  needs_bus: true
  generate_registers: false
  instantiate_directly: true
  dependency_only: false
reset:
  port: RESET_N
  active_high: false
clocking:
  primary_input_port: SYS_CLK
bus_interfaces:
  - port_name: axil
    protocol: axi_lite
    role: slave
    addr_width: 32
    data_width: 32
artifacts:
  synthesis: []
""",
        encoding="utf-8",
    )
    res = IpLoader().load_file(str(fp))
    assert res.ok
    ip = res.value
    assert ip.name == "axi_gpio"
    iface = ip.bus_interface(role="slave")
    assert iface is not None
    assert iface.protocol == "axi_lite"
    assert iface.port_name == "axil"


def test_load_ip_needs_bus_defaults_to_simple_bus(tmp_path):
    fp = tmp_path / "gpio.ip.yaml"
    fp.write_text(
        """
version: 2
kind: ip
ip:
  name: gpio
  module: gpio
  category: peripheral
origin:
  kind: source
  packaging: plain_rtl
integration:
  needs_bus: true
  generate_registers: false
  instantiate_directly: true
  dependency_only: false
reset:
  port: RESET_N
  active_high: false
clocking:
  primary_input_port: SYS_CLK
artifacts:
  synthesis: []
""",
        encoding="utf-8",
    )
    res = IpLoader().load_file(str(fp))
    assert res.ok
    ip = res.value
    iface = ip.bus_interface()
    assert iface is not None
    assert iface.protocol == "simple_bus"
    assert iface.port_name == "bus"


def test_load_ip_with_irqs(tmp_path):
    fp = tmp_path / "irq_gpio.ip.yaml"
    fp.write_text(
        """
version: 2
kind: ip
ip:
  name: irq_gpio
  module: irq_gpio
  category: peripheral
origin:
  kind: source
integration:
  needs_bus: true
  instantiate_directly: true
reset:
  port: RESET_N
clocking:
  primary_input_port: SYS_CLK
irqs:
  - name: changed
    id: 0
artifacts:
  synthesis: []
""",
        encoding="utf-8",
    )
    res = IpLoader().load_file(str(fp))
    assert res.ok
    irqs = res.value.meta.get("irqs", [])
    assert len(irqs) == 1
    assert irqs[0]["name"] == "changed"
    assert irqs[0]["id"] == 0
