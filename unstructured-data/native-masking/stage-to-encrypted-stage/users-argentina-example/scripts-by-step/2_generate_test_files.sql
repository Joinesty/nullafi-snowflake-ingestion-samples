-- =============================================================================
-- Step 2: Generate test files from USERS_ARGENTINA data
-- =============================================================================
-- Creates one file per format (CSV, JSON, XML, TXT, HTML, XLSX, PDF, PNG)
-- populated with real PII from POS.PUBLIC.USERS_ARGENTINA, and uploads them
-- to the landing stage. Used to exercise the pipeline end to end.
--
-- The PNG is intentionally included to demonstrate that native masking
-- skips images (they require the parse-extract pipeline).

CREATE OR REPLACE PROCEDURE POS.PUBLIC.GENERATE_TEST_FILES(TARGET_STAGE VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'openpyxl', 'reportlab', 'pillow')
HANDLER = 'run'
AS
$$
import csv
import json
import os
import tempfile
import xml.etree.ElementTree as ET

def run(session, target_stage):
    rows = session.sql("""
        SELECT ID, FIRST_NAME, LAST_NAME, EMAIL, CC_NUMBER, US_SSN, IBAN, PHONE_NUMBER, HOME_ADDRESS
        FROM POS.PUBLIC.USERS_ARGENTINA
        ORDER BY ID
        LIMIT 8
    """).collect()
    data = [r.as_dict() for r in rows]
    cols = ["ID", "FIRST_NAME", "LAST_NAME", "EMAIL", "CC_NUMBER", "US_SSN", "IBAN", "PHONE_NUMBER", "HOME_ADDRESS"]

    tmp = tempfile.mkdtemp()
    created = []

    csv_path = os.path.join(tmp, "users_sample.csv")
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for d in data:
            w.writerow({c: d[c] for c in cols})
    created.append(csv_path)

    json_path = os.path.join(tmp, "users_sample.json")
    with open(json_path, "w") as f:
        json.dump([{c: d[c] for c in cols} for d in data], f, indent=2, default=str)
    created.append(json_path)

    root = ET.Element("users")
    for d in data:
        u = ET.SubElement(root, "user")
        for c in cols:
            e = ET.SubElement(u, c.lower())
            e.text = str(d[c])
    xml_path = os.path.join(tmp, "users_sample.xml")
    ET.ElementTree(root).write(xml_path, encoding="utf-8", xml_declaration=True)
    created.append(xml_path)

    txt_path = os.path.join(tmp, "users_sample.txt")
    with open(txt_path, "w") as f:
        for d in data:
            f.write(f"Customer {d['FIRST_NAME']} {d['LAST_NAME']} | email: {d['EMAIL']} | "
                    f"card: {d['CC_NUMBER']} | ssn: {d['US_SSN']} | iban: {d['IBAN']} | "
                    f"phone: {d['PHONE_NUMBER']} | address: {d['HOME_ADDRESS']}\n")
    created.append(txt_path)

    html_path = os.path.join(tmp, "users_sample.html")
    with open(html_path, "w") as f:
        f.write("<html><body><h1>Customer Records</h1><table border='1'>")
        f.write("<tr>" + "".join(f"<th>{c}</th>" for c in cols) + "</tr>")
        for d in data:
            f.write("<tr>" + "".join(f"<td>{d[c]}</td>" for c in cols) + "</tr>")
        f.write("</table></body></html>")
    created.append(html_path)

    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Users"
    ws.append(cols)
    for d in data:
        ws.append([str(d[c]) for c in cols])
    xlsx_path = os.path.join(tmp, "users_sample.xlsx")
    wb.save(xlsx_path)
    created.append(xlsx_path)

    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas
    pdf_path = os.path.join(tmp, "users_sample.pdf")
    c = canvas.Canvas(pdf_path, pagesize=letter)
    y = 750
    c.setFont("Helvetica-Bold", 14)
    c.drawString(50, y, "Customer Records (Confidential)")
    c.setFont("Helvetica", 9)
    y -= 30
    for d in data:
        line = f"{d['FIRST_NAME']} {d['LAST_NAME']} | {d['EMAIL']} | card {d['CC_NUMBER']} | SSN {d['US_SSN']} | IBAN {d['IBAN']}"
        c.drawString(50, y, line[:110])
        y -= 18
        if y < 50:
            c.showPage(); y = 750
    c.save()
    created.append(pdf_path)

    from PIL import Image, ImageDraw
    img = Image.new("RGB", (900, 300), color="white")
    draw = ImageDraw.Draw(img)
    draw.text((10, 10), "Customer Record (scanned)", fill="black")
    yy = 50
    for d in data[:6]:
        draw.text((10, yy), f"{d['FIRST_NAME']} {d['LAST_NAME']}  email:{d['EMAIL']}  card:{d['CC_NUMBER']}  ssn:{d['US_SSN']}", fill="black")
        yy += 35
    png_path = os.path.join(tmp, "users_sample.png")
    img.save(png_path)
    created.append(png_path)

    uploaded = []
    for p in created:
        session.file.put(p, f"@{target_stage}", auto_compress=False, overwrite=True)
        uploaded.append(os.path.basename(p))
    session.sql(f"ALTER STAGE {target_stage} REFRESH").collect()
    return f"Generated and uploaded {len(uploaded)} files to @{target_stage}: " + ", ".join(uploaded)
$$;

-- Generate the files into the landing stage
CALL POS.PUBLIC.GENERATE_TEST_FILES('POS.PUBLIC.NULLAFI_LANDING_STAGE');
