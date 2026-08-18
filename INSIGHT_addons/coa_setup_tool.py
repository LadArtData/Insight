"""
coa_setup_tool.py

INSIGHT: Chart of Accounts (COA) Setup Tool -- Phase 1

Interactive CLI that interviews a solution consultant for Oracle Fusion
Chart of Accounts structure and segment details, validates the result
against core Fusion rules (at least one Primary Balancing Segment and one
Natural Account Segment), and writes the resulting configuration as a JSON
payload suitable for downstream API push.

Run directly:
    python coa_setup_tool.py

This file is standalone -- it has no dependency on the HTML wizard
(coa_setup_wizard.html) in this same delivery. The HTML wizard re-implements
this same question flow and validation logic in JavaScript so it can run in
a browser; the two are kept in sync by hand, not by shared code, since one
runs server/terminal-side and the other runs client-side.
"""

import json


def run_insight_phase_1():
    print("==================================================")
    print("   INSIGHT: Chart of Accounts (COA) Setup Tool    ")
    print("==================================================\n")

    # Step 1: Capture Metadata
    structure_name = input("Enter COA Structure Name (e.g., Acme_Global_COA): ").strip()
    delimiter = input("Enter Segment Delimiter [ - , . , | ]: ").strip()

    while delimiter not in ["-", ".", "|"]:
        delimiter = input("Invalid choice. Enter delimiter [ - , . , | ]: ").strip()

    num_segments = int(input("How many segments will this COA have? (e.g., 4): "))

    segments = []
    has_primary_balancing = False
    has_natural_account = False

    labels_map = {
        "1": "Primary Balancing Segment",
        "2": "Cost Center Segment",
        "3": "Natural Account Segment",
        "4": "Secondary Balancing Segment",
        "5": "Intercompany Segment",
        "6": "None"
    }

    # Step 2: Loop through segments
    for i in range(1, num_segments + 1):
        print(f"\n--- Setting up Segment {i} of {num_segments} ---")
        seg_name = input(f"Segment {i} Name (e.g., Company, Department): ").strip()

        print("\nSelect Segment Qualifier Label:")
        print("1. Primary Balancing Segment")
        print("2. Cost Center Segment")
        print("3. Natural Account Segment")
        print("4. Secondary Balancing Segment")
        print("5. Intercompany Segment")
        print("6. None")

        label_choice = input("Enter choice (1-6): ").strip()
        seg_label = labels_map.get(label_choice, "None")

        if seg_label == "Primary Balancing Segment":
            has_primary_balancing = True
        elif seg_label == "Natural Account Segment":
            has_natural_account = True

        max_len = int(input(f"Maximum character length for {seg_name} (e.g., 3 or 4): "))
        format_type = input("Format type [Numeric / Alphanumeric]: ").strip().capitalize()

        segment_obj = {
            "segmentSequence": i,
            "segmentName": seg_name,
            "segmentCode": seg_name.upper().replace(" ", "_"),
            "promptLabel": f"{seg_name} Code",
            "segmentLabel": seg_label,
            "valueSetDetails": {
                "valueSetName": f"VS_{structure_name.upper()}_{seg_name.upper()}",
                "dataType": "Character",
                "maximumLength": max_len,
                "formatType": format_type if format_type in ["Numeric", "Alphanumeric"] else "Numeric"
            }
        }
        segments.append(segment_obj)

    # Step 3: Validation Check
    print("\n==================================================")
    print("            VALIDATING FUSION RULES               ")
    print("==================================================")

    validation_passed = True

    if not has_primary_balancing:
        print("[X] ERROR: Fusion requires at least one 'Primary Balancing Segment'.")
        validation_passed = False
    if not has_natural_account:
        print("[X] ERROR: Fusion requires at least one 'Natural Account Segment'.")
        validation_passed = False

    if validation_passed:
        print("[\u2713] Validation Successful: All required Oracle Fusion segment labels are present.")

        # Step 4: Generate Payload
        payload = {
            "chartOfAccountsMetaData": {
                "structureName": structure_name,
                "structureCode": structure_name.upper().replace(" ", "_"),
                "delimiter": delimiter,
                "totalSegments": num_segments
            },
            "segments": segments
        }

        # Save to file
        filename = f"{structure_name}_coa_config.json"
        with open(filename, "w") as f:
            json.dump(payload, f, indent=2)

        print(f"\n[+] Configuration saved successfully to '{filename}'!")
        print("\n--- Generated JSON Payload ---")
        print(json.dumps(payload, indent=2))
    else:
        print("\n[!] Validation failed. Please re-run the setup and assign missing segment labels.")


if __name__ == "__main__":
    run_insight_phase_1()
