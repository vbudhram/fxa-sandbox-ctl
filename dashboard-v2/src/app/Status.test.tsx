// @vitest-environment jsdom
import { fireEvent, render, screen } from '@testing-library/react';
import { expect, test } from 'vitest';
import { ALERT_CAP, Alerts } from './Status';

test('the alerts strip shows the first few, and the rest behind a button', () => {
  const alerts = Array.from({ length: 40 }, (_, i) => ({ tone: 'warn' as const, subject: `EX-${i}`, what: 'idle 2d' }));
  const { container } = render(<Alerts alerts={alerts} ready />);
  expect(container.querySelectorAll('.alert')).toHaveLength(ALERT_CAP);
  fireEvent.click(screen.getByRole('button', { name: 'Show all 40 alerts' }));
  expect(container.querySelectorAll('.alert')).toHaveLength(40);
});
