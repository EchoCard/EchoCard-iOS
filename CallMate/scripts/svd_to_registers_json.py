#!/usr/bin/env python3
"""
Generate SF32LB52x_registers.json from CMSIS-SVD for iOS MCU Registers view.
Usage:
  python3 svd_to_registers_json.py [path_to_SF32LB52x.svd] [path_to_output.json]
Default: ../../LightWork_v2.3/svd/SF32LB52x.svd -> ../Resources/SF32LB52x_registers.json
"""

import json
import os
import sys
import xml.etree.ElementTree as ET


def parse_hex(text):
    if text is None:
        return 0
    s = (text.strip() or "0").lower()
    if s.startswith("0x"):
        return int(s[2:], 16)
    return int(s, 16)


def parse_svd(svd_path):
    tree = ET.parse(svd_path)
    root = tree.getroot()
    ns = {}
    peripherals = root.find("peripherals")
    if peripherals is None:
        return []

    out = []
    for periph in peripherals.findall("peripheral"):
        name_el = periph.find("name")
        base_el = periph.find("baseAddress")
        if name_el is None or base_el is None:
            continue
        name = (name_el.text or "").strip()
        base_hex = (base_el.text or "0").strip()
        base_int = parse_hex(base_el.text)

        regs_el = periph.find("registers")
        if regs_el is None:
            out.append({"name": name, "base": base_hex, "registers": []})
            continue

        reg_list = []
        for reg in regs_el.findall("register"):
            rname_el = reg.find("name")
            off_el = reg.find("addressOffset")
            if rname_el is None or off_el is None:
                continue
            rname = (rname_el.text or "").strip()
            offset_bytes = parse_hex(off_el.text)

            fields_el = reg.find("fields")
            fields = []
            if fields_el is not None:
                for field in fields_el.findall("field"):
                    fname_el = field.find("name")
                    boff_el = field.find("bitOffset")
                    bw_el = field.find("bitWidth")
                    if fname_el is None:
                        continue
                    fname = (fname_el.text or "").strip()
                    boff = int((boff_el.text or "0").strip(), 10)
                    bw = int((bw_el.text or "1").strip(), 10)
                    fields.append({"name": fname, "bitOffset": boff, "bitWidth": bw})

            reg_list.append({
                "addressOffset": offset_bytes,
                "name": rname,
                "fields": fields,
            })

        reg_list.sort(key=lambda r: r["addressOffset"])
        out.append({"name": name, "base": base_hex, "registers": reg_list})

    return out


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_svd = os.path.normpath(os.path.join(script_dir, "../../LightWork_v2.3/svd/SF32LB52x.svd"))
    default_out = os.path.normpath(os.path.join(script_dir, "../Resources/SF32LB52x_registers.json"))

    svd_path = sys.argv[1] if len(sys.argv) > 1 else default_svd
    out_path = sys.argv[2] if len(sys.argv) > 2 else default_out

    if not os.path.isfile(svd_path):
        print(f"Error: SVD file not found: {svd_path}", file=sys.stderr)
        sys.exit(1)

    data = parse_svd(svd_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"peripherals": data}, f, indent=2, ensure_ascii=False)

    total_regs = sum(len(p["registers"]) for p in data)
    print(f"Wrote {len(data)} peripherals, {total_regs} registers -> {out_path}")


if __name__ == "__main__":
    main()
