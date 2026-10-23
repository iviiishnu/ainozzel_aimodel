import os
import sys

# Tests import the service modules directly (inference, preprocessing, farm_app).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
