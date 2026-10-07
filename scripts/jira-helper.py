#!/usr/bin/env python3
"""
Jira Integration Helper for OpenShift Z-Stream CI on Power.
Supports:
1. Creating a Jira Task linked to an Epic (e.g., POCPQE-5) with standard checklist description.
2. Attaching logs and screenshots to a Jira issue.
3. Posting structured markdown/wiki comments containing:
   - Terraform / Cluster details
   - Cluster health check summary
   - E2E test results & failure breakdown
   - Inline screenshot thumbnails
"""

import os
import sys
import json
import glob
import mimetypes
import argparse
import urllib.request
import urllib.error
import ssl

JIRA_BASE_URL = os.environ.get("JIRA_BASE_URL", "https://jsw.ibm.com").rstrip("/")
JIRA_API_TOKEN = os.environ.get("JIRA_API_TOKEN", "")

def get_ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx

def make_request(endpoint, method="GET", data=None, headers=None):
    if headers is None:
        headers = {}
    
    url = f"{JIRA_BASE_URL}{endpoint}"
    headers["Authorization"] = f"Bearer {JIRA_API_TOKEN}"
    
    req_data = None
    if data is not None and isinstance(data, (dict, list)):
        req_data = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif data is not None:
        req_data = data

    req = urllib.request.Request(url, data=req_data, headers=headers, method=method)
    
    try:
        with urllib.request.urlopen(req, context=get_ssl_context(), timeout=60) as resp:
            content_type = resp.headers.get("Content-Type", "")
            resp_body = resp.read().decode("utf-8")
            if "application/json" in content_type and resp_body:
                return json.loads(resp_body)
            return resp_body
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8") if e.fp else str(e)
        print(f"ERROR: HTTP {e.code} on {method} {url}: {err_msg}", file=sys.stderr)
        raise
    except Exception as e:
        print(f"ERROR: Request failed {method} {url}: {e}", file=sys.stderr)
        raise

def get_epic_link_field_id():
    """
    Finds the customfield ID for 'Epic Link' in Jira.
    """
    try:
        fields = make_request("/rest/api/2/field", method="GET")
        if isinstance(fields, list):
            for f in fields:
                schema = f.get("schema", {})
                if schema.get("custom") == "com.pyxis.greenhopper.jira:gh-epic-link" or f.get("name") == "Epic Link":
                    return f.get("id")
    except Exception as e:
        print(f"Could not auto-detect epic link field id: {e}")
    return None

def create_jira_task(project_key, summary, description, epic_key=None):
    """
    Creates a Task in Jira and associates it with the specified Epic under 'Issues in epic'.
    """
    print(f"Creating Jira task under Project: {project_key}, Summary: '{summary}'...")

    fields = {
        "project": {"key": project_key},
        "summary": summary,
        "description": description,
        "issuetype": {"name": "Task"}
    }

    epic_field_id = get_epic_link_field_id() if epic_key else None
    if epic_field_id:
        print(f"Detected Epic Link field: {epic_field_id}")
        fields[epic_field_id] = epic_key

    issue_key = None
    try:
        resp = make_request("/rest/api/2/issue", method="POST", data={"fields": fields})
        issue_key = resp.get("key")
    except Exception as e:
        print(f"Direct creation with Epic Link failed: {e}. Trying creation without epic field first...")
        fields.pop(epic_field_id, None) if epic_field_id else None
        resp = make_request("/rest/api/2/issue", method="POST", data={"fields": fields})
        issue_key = resp.get("key")

    if epic_key and issue_key:
        # Move issue into Epic using Agile REST API (places it under "Issues in epic")
        link_issue_into_epic(issue_key, epic_key, epic_field_id)

    print(f"Successfully created Jira Issue: {issue_key}")
    return issue_key

def link_issue_into_epic(issue_key, epic_key, epic_field_id=None):
    """
    Associates an issue into an Epic so it shows under 'Issues in epic'.
    """
    print(f"Adding issue {issue_key} into Epic {epic_key} (Issues in epic)...")
    try:
        # 1. Jira Agile API endpoint
        make_request(f"/rest/agile/1.0/epic/{epic_key}/issue", method="POST", data={"issues": [issue_key]})
        print(f"Successfully added {issue_key} to Epic {epic_key} via Agile API.")
        return
    except Exception as e:
        print(f"Agile API epic move returned: {e}. Trying custom field update...")

    # 2. Fallback: Update Epic Link custom field via issue update
    if epic_field_id:
        try:
            make_request(f"/rest/api/2/issue/{issue_key}", method="PUT", data={"fields": {epic_field_id: epic_key}})
            print(f"Successfully set Epic Link {epic_field_id}={epic_key} on {issue_key}.")
            return
        except Exception as ex:
            print(f"Failed to set Epic Link custom field: {ex}")

def upload_attachment(issue_key, file_path):
    """
    Uploads a single file attachment to Jira using multipart/form-data.
    """
    if not os.path.exists(file_path):
        print(f"Skipping attachment, file not found: {file_path}")
        return None

    filename = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)
    if file_size == 0:
        print(f"Skipping empty file: {file_path}")
        return None

    print(f"Attaching {filename} ({file_size} bytes) to {issue_key}...")

    boundary = "----WebKitFormBoundaryJiraAttachment"
    content_type, _ = mimetypes.guess_type(file_path)
    if not content_type:
        content_type = "application/octet-stream"

    with open(file_path, "rb") as f:
        file_bytes = f.read()

    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode("utf-8") + file_bytes + f"\r\n--{boundary}--\r\n".encode("utf-8")

    headers = {
        "X-Atlassian-Token": "no-check",
        "Content-Type": f"multipart/form-data; boundary={boundary}"
    }

    try:
        endpoint = f"/rest/api/2/issue/{issue_key}/attachments"
        resp = make_request(endpoint, method="POST", data=body, headers=headers)
        print(f"Attached {filename} successfully.")
        return resp
    except Exception as e:
        print(f"WARNING: Failed to upload attachment {file_path} to {issue_key}: {e}", file=sys.stderr)
        return None

def post_comment(issue_key, comment_body):
    """
    Posts a comment to the specified Jira issue.
    """
    print(f"Posting comment to Jira Issue: {issue_key}...")
    endpoint = f"/rest/api/2/issue/{issue_key}/comment"
    data = {"body": comment_body}
    resp = make_request(endpoint, method="POST", data=data)
    print(f"Comment posted successfully to {issue_key}")
    return resp

def read_file_safe(path, max_chars=10000):
    if not path or not os.path.exists(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
            if len(content) > max_chars:
                return content[:max_chars] + f"\n... [Truncated {len(content) - max_chars} characters]"
            return content
    except Exception as e:
        return f"[Error reading {path}: {e}]"

def clean_version_str(ver):
    if not ver:
        return ""
    ver = ver.strip()
    if ":" in ver:
        ver = ver.split(":")[-1]
    if "-multi" in ver:
        ver = ver.replace("-multi", "")
    return ver

def build_comment_body(job_type, ocp_version, cluster_details_file, health_log_file, e2e_log_file, screenshots_dir, from_build="", to_build="", custom_title="", run_e2e=True):
    """
    Assembles Jira Wiki Markup formatted comment.
    """
    sections = []

    # Title assembly
    from_ver = clean_version_str(from_build)
    to_ver = clean_version_str(to_build or ocp_version)

    if custom_title:
        title = custom_title
    elif job_type == "direct-deploy":
        title = f"Direct install of {to_ver} on and run e2e"
    elif job_type == "current-upgrade":
        if from_ver and to_ver:
            title = f"Upgrade from {from_ver} to {to_ver} and run e2e"
        else:
            title = f"Upgrade to {to_ver} and run e2e"
    elif job_type == "next-upgrade":
        suffix = " and run e2e" if run_e2e else ""
        if from_ver and to_ver:
            title = f"Upgrade from {from_ver} to {to_ver}{suffix}"
        else:
            title = f"Upgrade from {to_ver} to next release{suffix}"
    else:
        title = f"Z-Stream Validation for {to_ver} - {job_type}"

    sections.append(f"h2. {title}\n")

    # Cluster Details
    cluster_details = read_file_safe(cluster_details_file)
    if cluster_details.strip():
        sections.append("h3. Cluster Details:\n{code:title=Terraform Outputs}\n" + cluster_details.strip() + "\n{code}\n")

    # Health Check
    health_details = read_file_safe(health_log_file, max_chars=15000)
    if health_details.strip():
        sections.append("h3. Basic Health Details on Cluster:\n{code:title=Cluster Health Check}\n" + health_details.strip() + "\n{code}\n")

    # E2E test results
    e2e_content = read_file_safe(e2e_log_file, max_chars=8000)
    if e2e_content.strip():
        sections.append("h3. E2E Test Summary:\n{code:title=E2E Log Summary}\n" + e2e_content.strip() + "\n{code}\n")

    # Screenshots inline thumbnails
    pngs = []
    if screenshots_dir and os.path.isdir(screenshots_dir):
        pngs = sorted(glob.glob(os.path.join(screenshots_dir, "**", "*.png"), recursive=True))
        if not pngs:
            pngs = sorted(glob.glob(os.path.join(screenshots_dir, "*.png")))
        if pngs:
            sections.append("h3. UI Console Screenshots:\n")
            thumb_links = " ".join([f"!{os.path.basename(p)}|thumbnail!" for p in pngs])
            sections.append(thumb_links + "\n")

    return "\n".join(sections)

def main():
    parser = argparse.ArgumentParser(description="Jira Automation Helper for Z-Stream CI")
    subparsers = parser.add_subparsers(dest="action", required=True)

    # Sub-command: create-task
    create_parser = subparsers.add_parser("create-task")
    create_parser.add_argument("--project", default="POCPQE", help="Jira Project Key (default: POCPQE)")
    create_parser.add_argument("--epic", default="POCPQE-2576", help="Jira Epic Key (default: POCPQE-2576)")
    create_parser.add_argument("--release", required=True, help="OCP Z-stream version, e.g. 4.19.50")
    create_parser.add_argument("--current-stable", default="", help="Previous stable build, e.g. 4.19.49")
    create_parser.add_argument("--next-stable", default="", help="Next release stable build, e.g. 4.20.41")
    create_parser.add_argument("--output-file", help="File to write the created issue key into")

    # Sub-command: post-report
    report_parser = subparsers.add_parser("post-report")
    report_parser.add_argument("--issue", required=True, help="Jira Issue Key, e.g. POCPQE-2563")
    report_parser.add_argument("--job-type", choices=["direct-deploy", "current-upgrade", "next-upgrade"], required=True)
    report_parser.add_argument("--release", required=True, help="OCP release version, e.g. 4.19.50")
    report_parser.add_argument("--from-build", default="", help="Starting build version, e.g. 4.19.49")
    report_parser.add_argument("--to-build", default="", help="Target build version, e.g. 4.19.50")
    report_parser.add_argument("--title", default="", help="Override title for Jira comment")
    report_parser.add_argument("--run-e2e", default="true", help="Whether e2e was executed (true/false)")
    report_parser.add_argument("--cluster-details", help="Path to cluster details / terraform vars file")
    report_parser.add_argument("--health-log", help="Path to cluster-health.log")
    report_parser.add_argument("--e2e-log", help="Path to e2e summary log")
    report_parser.add_argument("--screenshots-dir", help="Directory containing UI screenshot PNGs")
    report_parser.add_argument("--extra-attachments", nargs="*", default=[], help="Extra files to attach")

    args = parser.parse_args()

    if not JIRA_API_TOKEN:
        print("ERROR: JIRA_API_TOKEN environment variable is not set. Skipping Jira operations.", file=sys.stderr)
        sys.exit(0)

    if args.action == "create-task":
        summary = f"Validate zstream OCP {args.release} on Power"
        
        # Build description list matching user's checklist
        desc_lines = ["Description:"]
        desc_lines.append(f"* Direct install of {args.release} on and run e2e (Checking Jenkins for existing jobs)")
        if args.current_stable:
            desc_lines.append(f"* Upgrade from {args.current_stable} to {args.release} and run e2e")
        else:
            desc_lines.append(f"* Upgrade to {args.release} and run e2e")
        if args.next_stable:
            desc_lines.append(f"* Upgrade from {args.release} to {args.next_stable} and run e2e")
        
        description = "\n".join(desc_lines)
        issue_key = create_jira_task(args.project, summary, description, epic_key=args.epic)
        
        if args.output_file and issue_key:
            with open(args.output_file, "w") as f:
                f.write(issue_key.strip())
        print(f"JIRA_TICKET_KEY={issue_key}")

    elif args.action == "post-report":
        issue_key = args.issue.strip()
        if not issue_key:
            print("No JIRA issue key specified. Skipping.")
            sys.exit(0)

        # 1. Upload screenshots (both individual PNGs recursively and the tar.gz archive if present)
        if args.screenshots_dir and os.path.isdir(args.screenshots_dir):
            png_list = sorted(glob.glob(os.path.join(args.screenshots_dir, "**", "*.png"), recursive=True))
            if not png_list:
                png_list = sorted(glob.glob(os.path.join(args.screenshots_dir, "*.png")))
            for png in png_list:
                upload_attachment(issue_key, png)
        
        # Also check for ui-screenshots.tar.gz in deploy or workspace
        tar_candidates = [
            os.path.join(os.path.dirname(args.screenshots_dir or ""), "ui-screenshots.tar.gz"),
            "deploy/ui-screenshots.tar.gz",
            "ui-screenshots.tar.gz"
        ]
        for tar_path in tar_candidates:
            if os.path.isfile(tar_path):
                upload_attachment(issue_key, tar_path)
                break

        # 2. Upload health log & extra attachments
        if args.health_log and os.path.isfile(args.health_log):
            upload_attachment(issue_key, args.health_log)

        for extra in args.extra_attachments:
            if os.path.isfile(extra):
                upload_attachment(issue_key, extra)

        # 3. Build comment & post
        is_e2e = str(args.run_e2e).lower() in ["true", "1", "yes"]
        comment_body = build_comment_body(
            job_type=args.job_type,
            ocp_version=args.release,
            cluster_details_file=args.cluster_details,
            health_log_file=args.health_log,
            e2e_log_file=args.e2e_log,
            screenshots_dir=args.screenshots_dir,
            from_build=args.from_build,
            to_build=args.to_build,
            custom_title=args.title,
            run_e2e=is_e2e
        )
        post_comment(issue_key, comment_body)

if __name__ == "__main__":
    main()
