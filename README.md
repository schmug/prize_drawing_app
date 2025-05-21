# NCLGISA Conference Prize Drawing Application

## Overview

This Flask web application provides a fair and manageable system for conducting random prize drawings during the NCLGISA conference. It allows administrators to import lists of registered conference members, perform random drawings, track winners, and ensure that all eligible attendees have a chance to win.

The application is designed with simplicity and mobile-friendliness in mind, allowing for easy operation during the event, potentially via a mobile device using tools like ngrok for access.

## Features

*   **PIN Protection**: Access to the application's drawing and administrative functions is protected by a 6-digit PIN.
*   **Member Import from CSV**: 
    *   Administrators can import lists of registered conference members directly from a CSV file.
    *   The import function is designed to add only new members (based on a unique `Registration_Badge_ID`) to the database, ensuring that existing members (including those who have already won) are not duplicated or have their status improperly reset.
    *   This allows for ongoing updates throughout the conference. As new members register, a new CSV can be imported to add them to the pool of eligible participants for subsequent drawings.
    *   The import process specifically filters for actual members, excluding guest registrations if marked accordingly in the CSV (expects an 'Is_Member?' column with 'Yes' for members).
*   **Random Drawing Mechanism**: 
    *   The application uses Python's built-in `random.choice()` function to select a winner from the pool of currently eligible members.
    *   **Randomness Explanation**: `random.choice()` selects an item uniformly at random from a sequence. This means every member currently eligible for the drawing has an equal probability of being selected. For the purposes of a prize drawing at a conference, this level of pseudo-randomness is considered cryptographically sufficient and fair. It ensures that the selection is unbiased and that each draw is independent of previous draws (unless a winner is removed from the pool).
*   **Winner Handling**: 
    *   When a member is drawn, the administrator can mark the prize as "Claimed" or indicate that the person was "Not Here."
    *   **Claimed**: If the prize is claimed, the member is recorded as a winner and is made ineligible for future drawings in this event instance.
    *   **Not Here**: If the drawn member is not present, they are logged as "Not Here" in the audit trail but critically, they are **put back into the pool of eligible attendees** and can be drawn again in a future drawing.
*   **Audit Log**: 
    *   All drawing events are logged, including the member drawn, their organization, the timestamp, and the status (i.e., "Claimed" or "Not Here").
    *   This provides a complete audit trail of the drawing process.
*   **Admin Reset Functionality**: 
    *   An administrative function allows for a full reset of the drawing system.
    *   This action clears all winner logs and marks all members as eligible for drawing again.
    *   A confirmation step (typing "reset") is required to prevent accidental resets.
    *   This is useful for testing or for starting fresh for different major drawing sessions if needed.
*   **Test Data Cleanup**: A Flask CLI command (`flask clean-test-data`) is available for developers/administrators to remove any test entries (identified by `Registration_Badge_ID` starting with "TEST") from the database.
*   **Mobile-Friendly Interface**: The web interface is built with Bootstrap and designed to be responsive for use on mobile devices.

## Technical Details

*   **Backend**: Flask (Python web framework)
*   **Database**: SQLite (via Flask-SQLAlchemy)
*   **Frontend**: HTML, Bootstrap 4, Jinja2 templating
*   **Deployment**: Intended to be run on a Linux server using Gunicorn as the WSGI server and Nginx as a reverse proxy.

## Setup and Usage

(This section would typically include instructions on local development setup and server deployment, which we have covered extensively in our interactions. For this README, we are focusing on the application's features and logic as requested.)

### Data Import

1.  Prepare your CSV file of registered members. The application expects specific column names (e.g., `Registration_Badge_ID`, `First_Name`, `Last_Name`, `Work Email Address Do not use personal`, `Organization`, `Is_Member?`).
2.  Log in to the application using the PIN.
3.  Navigate to the "Import Data" page.
4.  Upload the CSV file. New members will be added to the drawing pool.

### Performing a Drawing

1.  Ensure all eligible members are imported.
2.  Log in to the application using the PIN.
3.  From the main page, click the "Draw Winner" button.
4.  The drawn winner's name and organization will be displayed.
5.  Select "Claimed Prize" if the member is present and claims their prize. They will be removed from future drawings.
6.  Select "Not Here (Redraw)" if the member is not present. They will be logged as "Not Here" but remain eligible, and a new drawing will be automatically initiated.

### Viewing Past Drawings

*   Navigate to the "Audit Log" page to see a history of all drawings, including who was drawn and whether they claimed their prize or were not present.

### Resetting Drawings (Admin)

1.  Log in to the application using the PIN.
2.  Navigate to the "Admin Reset" link (typically in the footer).
3.  Carefully read the warning. To proceed, type "reset" into the confirmation box and submit.
    This will clear all drawing logs and make all members eligible again.

## Security and Configuration

*   **PIN**: The application access PIN is configured via the `DRAWING_APP_PIN` environment variable on the server. For local development without this variable set, it defaults to `123456`.
*   **Flask Secret Key**: The `FLASK_SECRET_KEY` for session management must be set as an environment variable for production deployments.
*   **Data Files**: Registrant CSV files, the live SQLite database (`drawing.db`), and environment files (`.env`, `.env.local`) are excluded from the Git repository via `.gitignore` to protect sensitive information. A template `.env.example` is provided for creating your own `.env.local` file.

---

This README provides a functional overview. For detailed setup, deployment, and code structure, refer to the project files and associated deployment scripts. 

---

**Development Note:** ALL code and documentation for this application was 100% coded without the "coder" (human user) ever looking at a single line of code for review or changes prior to its generation. This project was coded using Agentic coding principles from plain language inputs, iterative reasoning, and troubleshooting with Cursor.ai, powered by the LLM: Google Gemini 2.5 Pro. Approximately 2 hours and 10 minutes were spent from start to finish on this iterative coding process, including understanding the prize committee's intent for the application, data considerations, development for the Linux server, application testing, and full documentation. 