import sys

def parse_vcd(filename):
    with open(filename, "r") as f:
        # Find signal definitions
        signals = {}
        for line in f:
            if line.strip().startswith("$var"):
                parts = line.split()
                if len(parts) >= 5:
                    if "dp_start_o" in parts or "exit_valid_o" in parts or "dp_done_i" in parts or "funct3_i" in parts or "x_result_valid_o" in parts or "dp_funct3_o" in parts:
                        signals[parts[3]] = parts[4]
            elif line.strip().startswith("$enddefinitions"):
                break
        
        print("Signals found:", signals)
        
        # Now track values
        time = 0
        for line in f:
            if line.strip().startswith("#"):
                time = int(line[1:])
                if time > 200000: break
            elif line[0] in "01xXzZ" and len(line) > 1:
                val = line[0]
                code = line[1:].strip()
                if code in signals:
                    print(f"Time {time}: {signals[code]} = {val}")
            elif line[0] == "b":
                parts = line.split()
                val = parts[0][1:]
                code = parts[1].strip()
                if code in signals:
                    print(f"Time {time}: {signals[code]} = {val}")

parse_vcd("sim.vcd")
