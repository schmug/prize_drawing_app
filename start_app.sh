#!/bin/bash

# Ensure Flask environment variables are set (optional, but good practice)
export FLASK_APP=app.py
export FLASK_ENV=development # Enables debug mode among other things

# Initialize the database (creates tables and imports initial data if DB is empty)
flask init-db

# Run the Flask application on port 8080
# The app.py itself is already configured to run on port 8080 with debug=False
flask run --host=0.0.0.0 --port=8080

# Alternative using python directly if you prefer (app.py already sets port and debug):
# python app.py 