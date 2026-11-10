// The Pipeline view: Belts, Queue and Done. It has no side list and no details panel, as in v1.
import { LazyMotion, MotionConfig } from 'motion/react';
import type { ViewChunk } from '../../app/views';
import { useApp } from '../../store';
import { Belts } from './belts';
import { Done } from './done';
import { Queue } from './queue';
import './pipeline.css';

const features = () => import('./motion').then((m) => m.default);

function Main() {
  const tab = useApp((s) => s.route.tab);
  return (
    <MotionConfig reducedMotion="user">
      <LazyMotion features={features}>
        {tab === 'queue' ? <Queue /> : tab === 'done' ? <Done /> : <Belts />}
      </LazyMotion>
    </MotionConfig>
  );
}

export default { Main } satisfies ViewChunk;
