# OpenProject Time Tracker

A console app that lists the days in a date range with fewer than 8 logged hours
and lets you log time against a work package. It runs on Windows PowerShell 5.1
or PowerShell 7+ and needs nothing installed.

## 1. Get your API token

1. Log in to your OpenProject website.
2. Click your avatar in the top-right corner and choose **My account**.
3. In the left menu, open **Access tokens**.
4. In the **API** section, click **+ API token** (older versions show a
   **Generate** button instead). Give it a name if asked, e.g. `Time tracker`.
5. Copy the token straight away. OpenProject shows it only once. If you lose it,
   delete it and create a new one.

If there is no **API** section, the REST API is switched off for your instance.
Ask an administrator to enable it under
**Administration → API and webhooks → Enable REST web service**.

## 2. Configure

Copy `.env.example` to `.env` next to the script and fill in your values:

```
OPENPROJECT_URL=https://your-instance.openproject.com
OPENPROJECT_TOKEN=paste-your-token-here
```

If either value is missing, the script asks for it when it starts.

The token gives full access to your account, so never commit `.env` or share it.

## 3. Run

The easiest way: in File Explorer, right-click `openproject_timetracker.ps1` and
choose **Run with PowerShell**. On Windows 11 it may be under
**Show more options**. The window closes as soon as the script ends.

Or run it from a PowerShell window:

```powershell
.\openproject_timetracker.ps1
```

If PowerShell refuses to run scripts, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\openproject_timetracker.ps1
```
