from flask import Flask, render_template, request, redirect, url_for, flash, session
from flask_sqlalchemy import SQLAlchemy
import secrets
import csv
import os
from datetime import datetime # Added for Winner timestamp
from werkzeug.utils import secure_filename # For secure file uploads
from functools import wraps # For the PIN decorator

# Determine the absolute path for the project directory
BASE_DIR = os.path.abspath(os.path.dirname(__file__))

app = Flask(__name__)
# Use an absolute path for the database
app.config['SQLALCHEMY_DATABASE_URI'] = f"sqlite:///{os.path.join(BASE_DIR, 'drawing.db')}"
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
# Expect FLASK_SECRET_KEY to be set in the environment for production
app.secret_key = os.environ.get('FLASK_SECRET_KEY')
if app.secret_key is None:
    print("CRITICAL: FLASK_SECRET_KEY is not set in the environment! Using a temporary insecure key for local/direct run.")
    # This fallback is for direct `python app.py` execution without .env or Gunicorn loading it.
    # For Gunicorn, ensure FLASK_SECRET_KEY is in the .env file loaded by the systemd service.
    app.secret_key = 'temp_insecure_dev_key_only_for_direct_run' 

app.config['UPLOAD_FOLDER'] = os.path.join(BASE_DIR, 'uploads')
# Use a generic name for the default CSV, actual file should be renamed to match if used for initial import
DEFAULT_CSV_FILE_PATH = os.path.join(BASE_DIR, 'initial_registrants.csv') 
# Load PIN from environment variable, with a non-production default
APP_PIN = os.environ.get("DRAWING_APP_PIN", "123456") 
ADMIN_RESET_CONFIRMATION_TEXT = "reset"

os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

db = SQLAlchemy(app)

# --- Database Models ---
class Member(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    registration_badge_id = db.Column(db.String(100), unique=True, nullable=False) # Made unique
    first_name = db.Column(db.String(100), nullable=False)
    last_name = db.Column(db.String(100), nullable=False)
    organization = db.Column(db.String(200))
    # Email is not strictly required to be unique if multiple people from one org share an admin email, but badge ID should be.
    # However, for drawing purposes, unique email might be better if badge ID isn't always the primary key from source.
    email = db.Column(db.String(120), nullable=False) # Removed unique=True based on discussion, badge_id is main identifier
    is_member = db.Column(db.Boolean, default=True)
    eligible_for_drawing = db.Column(db.Boolean, default=True)

    def __repr__(self):
        return f'<Member {self.first_name} {self.last_name}>'

class Winner(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    member_id = db.Column(db.Integer, db.ForeignKey('member.id'), nullable=False)
    member = db.relationship('Member', backref=db.backref('wins', lazy=True))
    timestamp = db.Column(db.DateTime, default=datetime.utcnow)
    status = db.Column(db.String(20), nullable=False, default='claimed') # New column: 'claimed' or 'not_here'

    def __repr__(self):
        return f'<Winner {self.member.first_name} {self.member.last_name} - Status: {self.status} at {self.timestamp}>'

# --- PIN Protection Decorator ---
def pin_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('pin_verified'):
            flash('Please enter the PIN to access this page.', 'warning')
            return redirect(url_for('login', next=request.url))
        return f(*args, **kwargs)
    return decorated_function

# --- Routes ---
@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        entered_pin = request.form.get('pin')
        if entered_pin == APP_PIN:
            session['pin_verified'] = True
            flash('PIN accepted!', 'success')
            next_page = request.args.get('next')
            return redirect(next_page or url_for('index'))
        else:
            flash('Invalid PIN.', 'danger')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('pin_verified', None)
    flash('You have been logged out.', 'info')
    return redirect(url_for('login'))

# --- Admin Routes ---
@app.route('/admin/reset_drawings', methods=['GET', 'POST'])
@pin_required
def admin_reset_drawings():
    if request.method == 'POST':
        confirmation = request.form.get('confirmation_text')
        if confirmation == ADMIN_RESET_CONFIRMATION_TEXT:
            try:
                # Delete all entries from Winner table
                num_winners_deleted = db.session.query(Winner).delete()
                # Reset all members to be eligible for drawing
                num_members_reset = Member.query.update({'eligible_for_drawing': True})
                db.session.commit()
                flash(f'Successfully reset all drawings. {num_winners_deleted} winner/log entries deleted. {num_members_reset} members made eligible.', 'success')
            except Exception as e:
                db.session.rollback()
                flash(f'Error resetting drawings: {str(e)}', 'danger')
            return redirect(url_for('admin_reset_drawings')) # Redirect to GET to clear form
        else:
            flash('Confirmation text did not match. Reset was not performed.', 'danger')
    return render_template('admin_reset_drawings.html', confirmation_text_required=ADMIN_RESET_CONFIRMATION_TEXT)

# --- Helper Functions ---
def import_members_from_csv(csv_file_path, use_flash=True):
    members_added_count = 0
    members_updated_count = 0
    members_skipped_count = 0
    try:
        with open(csv_file_path, mode='r', encoding='utf-8-sig') as infile: # utf-8-sig for potential BOM
            reader = csv.DictReader(infile)
            for row in reader:
                is_actual_member = row.get('Is_Member?', '').strip().lower() == 'yes'
                if not is_actual_member:
                    members_skipped_count +=1
                    continue

                badge_id = row.get('Registration_Badge_ID')
                email = row.get('Work Email Address Do not use personal', '').strip()
                first_name = row.get('First_Name', '').strip()
                last_name = row.get('Last_Name', '').strip()

                if not badge_id or not first_name or not last_name or not email:
                    # This print is fine for both CLI and server logs
                    print(f"Skipping row due to missing critical data (Badge ID, Name, or Email): {row}")
                    members_skipped_count +=1
                    continue

                existing_member = Member.query.filter_by(registration_badge_id=badge_id).first()
                if not existing_member:
                    member = Member(
                        registration_badge_id=badge_id,
                        first_name=first_name,
                        last_name=last_name,
                        organization=row.get('Organization', ''),
                        email=email,
                        is_member=True,
                        eligible_for_drawing=True
                    )
                    db.session.add(member)
                    members_added_count += 1
                else:
                    existing_member.first_name = first_name
                    existing_member.last_name = last_name
                    existing_member.organization = row.get('Organization', '')
                    existing_member.email = email
                    existing_member.is_member = True
                    existing_member.eligible_for_drawing = True
                    members_updated_count += 1
            db.session.commit()
        
        message = (
            f"Successfully added {members_added_count} members and updated "
            f"{members_updated_count} members. Skipped {members_skipped_count} "
            "(non-members/missing data)."
        )
        if use_flash:
            flash(message, 'success')
        else:
            print(message)
        return True
    except FileNotFoundError:
        message = f"Error: CSV file not found at {csv_file_path}"
        if use_flash:
            flash(message, 'danger')
        else:
            print(message)
        return False
    except Exception as e:
        db.session.rollback()
        message = f"Error importing CSV: {e}"
        if use_flash:
            flash(message, 'danger')
        # Always print the exception for server logs/CLI
        print(message) 
        return False

# --- Protected Routes ---
@app.route('/')
@pin_required
def index():
    winner_data = session.pop('winner_data', None) # Get winner data if redirected from /draw
    last_winner_info = None
    last_win = Winner.query.order_by(Winner.timestamp.desc()).first()
    if last_win:
        last_winner_info = {
            'name': f"{last_win.member.first_name} {last_win.member.last_name}",
            'organization': last_win.member.organization
        }
    return render_template('index.html', winner=winner_data, last_winner_info=last_winner_info)

@app.route('/draw')
@pin_required
def draw():
    eligible_members = Member.query.filter_by(eligible_for_drawing=True, is_member=True).all()
    if not eligible_members:
        flash('No eligible members left to draw from!', 'warning')
        return redirect(url_for('index'))

    winner = secrets.choice(eligible_members)
    # Store winner data in session to display on index page after redirect
    session['winner_data'] = {
        'id': winner.id, 
        'first_name': winner.first_name, 
        'last_name': winner.last_name, 
        'organization': winner.organization
    }
    return redirect(url_for('index'))

@app.route('/handle_winner/<int:member_id>/<action>')
@pin_required
def handle_winner(member_id, action):
    member = Member.query.get_or_404(member_id)
    if action == 'claimed':
        member.eligible_for_drawing = False
        new_winner_log = Winner(member_id=member.id, status='claimed')
        db.session.add(new_winner_log)
        db.session.commit()
        flash(f'{member.first_name} {member.last_name} from {member.organization} claimed their prize!', 'success')
    elif action == 'not_here':
        # Log that the person was not here
        not_here_log = Winner(member_id=member.id, status='not_here')
        db.session.add(not_here_log)
        # Member remains eligible_for_drawing = True (no change needed from current state)
        db.session.commit()
        flash(f'{member.first_name} {member.last_name} was not present. A record has been made. Redrawing...', 'info')
        return redirect(url_for('draw')) 
    else:
        flash('Invalid action.', 'danger')
    return redirect(url_for('index'))

@app.route('/winners')
@pin_required
def winners_list():
    winners = Winner.query.order_by(Winner.timestamp.desc()).all()
    return render_template('winners_list.html', winners=winners)

@app.route('/import', methods=['GET', 'POST'])
@pin_required
def import_data_route():
    if request.method == 'POST':
        if 'csvfile' not in request.files:
            flash('No file part', 'warning')
            return redirect(request.url)
        file = request.files['csvfile']
        if file.filename == '':
            flash('No selected file', 'warning')
            return redirect(request.url)
        if file and file.filename.lower().endswith('.csv'):
            filename = secure_filename(file.filename)
            save_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
            file.save(save_path)
            import_members_from_csv(save_path)
            return redirect(url_for('index'))
        else:
            flash('Invalid file type. Please upload a CSV file.', 'danger')
            return redirect(request.url)
    return render_template('import_data.html', current_csv_path=DEFAULT_CSV_FILE_PATH)

@app.cli.command('init-db')
def init_db_command():
    """Creates the database tables and imports initial data."""
    db.create_all()
    print("Database tables created.")
    if Member.query.count() == 0: # Only import if DB is empty
        if import_members_from_csv(DEFAULT_CSV_FILE_PATH, use_flash=False):
            # Message already printed by the function
            pass
        else:
            # Message already printed by the function
            pass
    else:
        print("Database already contains data. Skipping initial import.")

@app.cli.command('clean-test-data')
def clean_test_data_command():
    """Removes members with Registration_Badge_ID starting with TEST and their associated winner logs."""
    with app.app_context(): # Ensure we are in app context for db operations
        test_members = Member.query.filter(Member.registration_badge_id.like('TEST%')).all()
        if not test_members:
            print("No test members (Registration_Badge_ID starting with TEST) found.")
            return

        member_ids_to_delete = [member.id for member in test_members]
        deleted_member_count = 0
        deleted_winner_log_count = 0

        try:
            # Delete associated winner logs first
            if member_ids_to_delete:
                winner_logs_deleted_result = Winner.query.filter(Winner.member_id.in_(member_ids_to_delete)).delete(synchronize_session=False)
                deleted_winner_log_count = winner_logs_deleted_result if winner_logs_deleted_result is not None else 0

            # Delete the test members
            member_delete_result = Member.query.filter(Member.id.in_(member_ids_to_delete)).delete(synchronize_session=False)
            deleted_member_count = member_delete_result if member_delete_result is not None else 0
            
            db.session.commit()
            print(f"Successfully deleted {deleted_member_count} test members and {deleted_winner_log_count} associated winner logs.")
        except Exception as e:
            db.session.rollback()
            print(f"Error cleaning test data: {str(e)}")

if __name__ == '__main__':
    # This block is mainly for local development.
    # For production, Gunicorn is used.
    if not app.secret_key or app.secret_key == 'temp_insecure_dev_key_only_for_direct_run':
        print("Warning: FLASK_SECRET_KEY is not set or is insecure. Using a temporary insecure key for local development via python app.py.")
        print("For production, ensure FLASK_SECRET_KEY is properly set in the environment.")
        app.secret_key = 'temp_insecure_dev_key_only_for_direct_run'
    
    # For local testing, if DRAWING_APP_PIN is not set, it will use the default "123456"
    print(f"INFO: Using APP_PIN: {APP_PIN} (Set DRAWING_APP_PIN env var to override for local dev)")

    with app.app_context(): 
        db.create_all() 
        if Member.query.count() == 0: 
             if os.path.exists(DEFAULT_CSV_FILE_PATH):
                print(f"Attempting to import initial data from {DEFAULT_CSV_FILE_PATH}...")
                import_members_from_csv(DEFAULT_CSV_FILE_PATH, use_flash=False)
             else:
                print(f"Default CSV file {DEFAULT_CSV_FILE_PATH} not found. Skipping initial import. Please use the import page once the app is running.")
    # The port and debug flag are set here for direct execution (python app.py)
    # Gunicorn will have its own settings.
    app.run(debug=False, port=8080, host='0.0.0.0') 