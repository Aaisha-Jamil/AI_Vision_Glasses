import os
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

def main_menu():
    print("\n" + "=" * 60)
    print("   PRIVACY-PRESERVING LECTURE SYNTHESIS PLATFORM")
    print("=" * 60)
    print("\nStarting Lecture Video Mode...")
    print("-" * 60)

    from lecture import run_lecture_mode
    run_lecture_mode()

if __name__ == "__main__":
    main_menu()