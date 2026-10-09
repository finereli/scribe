import {Composition} from 'remotion';
import {Scribe, DURATION, FPS} from './Scribe';

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="ScribeDark"
      component={Scribe}
      durationInFrames={DURATION}
      fps={FPS}
      width={1080}
      height={1080}
      defaultProps={{theme: 'dark' as const}}
    />
    <Composition
      id="ScribeLight"
      component={Scribe}
      durationInFrames={DURATION}
      fps={FPS}
      width={1080}
      height={1080}
      defaultProps={{theme: 'light' as const}}
    />
  </>
);
