# CallMate scripts

## SVD → Register names (SF32LB52x)

Generates `SF32LB52x_registers.json` from the chip's CMSIS-SVD so the app can show register names and bit fields in **Device → MCU Registers**.

**Usage:**

```bash
cd CallMate
python3 scripts/svd_to_registers_json.py
```

- **Input (default):** `LightWork_v2.3/svd/SF32LB52x.svd`
- **Output (default):** `CallMate/Resources/SF32LB52x_registers.json`

Override paths:

```bash
python3 scripts/svd_to_registers_json.py /path/to/SF32LB52x.svd /path/to/output.json
```

After generation, the JSON is under `CallMate/Resources/` and is included in the app via the project's synchronized CallMate folder. Rebuild the app to see register names and field breakdown in the MCU Registers screen.
