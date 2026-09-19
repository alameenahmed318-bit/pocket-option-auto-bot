import os
from dotenv import load_dotenv

load_dotenv()
DEMO_ONLY = os.getenv('DEMO_ONLY', 'true').lower() == 'true'
STAKE = float(os.getenv('STAKE', '1'))
MAX_TRADES_PER_RUN = int(os.getenv('MAX_TRADES_PER_RUN', '3'))
MAX_DAILY_LOSS = float(os.getenv('MAX_DAILY_LOSS', '3'))

def validate_config():
    if not DEMO_ONLY:
        raise RuntimeError('Live execution is intentionally blocked in this scaffold.')
    if STAKE <= 0 or MAX_TRADES_PER_RUN < 1 or MAX_DAILY_LOSS <= 0:
        raise ValueError('Invalid risk configuration.')

def main():
    validate_config()
    print('Pocket Option bot scaffold started in DEMO_ONLY mode.')
    print(f'Stake=${STAKE:.2f}, max trades/run={MAX_TRADES_PER_RUN}, daily loss=${MAX_DAILY_LOSS:.2f}')
    print('No broker execution yet: API adapter must be reviewed and connected first.')

if __name__ == '__main__':
    main()
