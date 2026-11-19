// How long one `bash` call may run. Pi Durable's bash has no default timeout,
// so a model that gives none can leave a command running for hours: a
// recursive grep over a home folder once ran for nearly two hours before
// someone killed it by hand. Every call now gets a limit, the default unless
// the model asks for its own, and never more than the cap.
//
// At the limit the computer's environment kills the command's whole process
// group, not just its shell: each command starts in a session of its own,
// locally (Pi Durable's NodeExecutionEnv, `detached`) and on a Sprite or over
// SSH (the pi-env daemon, which kills the group with SIGKILL). So a pipeline
// and what it sent to the background end with it.
import { num, obj, opt, str } from '@earendil-works/pi-schema';
import { defineExtension, wrapTool } from '@earendil-works/pi-durable';

export const BASH_DEFAULT_TIMEOUT_SECONDS = 600;
export const BASH_TIMEOUT_CAP_SECONDS = 3600;

// A longer timeout is cut to the cap rather than refused: a refusal costs the
// model a turn, and one that retries without a timeout gets less time, not more.
// What is not a positive number is left for the tool to refuse.
export function bashTimeout(requested, defaultSeconds) {
  if (requested === undefined) return defaultSeconds;
  return typeof requested === 'number' && requested > BASH_TIMEOUT_CAP_SECONDS ? BASH_TIMEOUT_CAP_SECONDS : requested;
}

export function duration(seconds) {
  if (seconds >= 60 && seconds % 60 === 0) return `${seconds / 60} minutes`;
  return `${seconds} ${seconds === 1 ? 'second' : 'seconds'}`;
}

const limitsSaid = defaultSeconds => `Commands stop after ${duration(defaultSeconds)} unless given a timeout in seconds, ` +
  `which may be at most ${duration(BASH_TIMEOUT_CAP_SECONDS)}; at the limit everything the command started is ended.`;

// The `bash` of Pi Durable's coding tools, with its limit. `defaultSeconds`
// is the install's (limits.bashTimeoutMs), at most the cap.
export function bashLimit({ defaultSeconds = BASH_DEFAULT_TIMEOUT_SECONDS } = {}) {
  return defineExtension({ name: 'omakase.bash-limit', wraps: [wrapTool({ name: 'bash' }, bash => ({
    ...bash,
    description: `${bash.description.replace(/ ?Optionally provide a timeout in seconds\.$/, '')} ${limitsSaid(defaultSeconds)}`,
    parameters: obj({
      command: str({ description: 'Bash command to execute' }),
      timeout: opt(num({ description: `Timeout in seconds (optional; default ${defaultSeconds}, at most ${BASH_TIMEOUT_CAP_SECONDS})` }))
    }, { open: true }),
    async execute(args, api, context) {
      const timeout = bashTimeout(args.timeout, defaultSeconds);
      try {
        return await bash.execute({ ...args, timeout }, api, context);
      } catch (error) {
        // Pi Durable throws this text for its timeout and nothing else.
        if (error?.message !== `Command timed out after ${timeout} seconds`) throw error;
        const given = args.timeout === undefined ? 'the limit when no timeout is given' :
          timeout === args.timeout ? 'the timeout it was given' : `the most a command may run (it asked for ${duration(args.timeout)})`;
        // No output here: the result keeps what the command printed so far.
        return { isError: true, diagnostics: [{ severity: 'error', code: 'timeout',
          message: `bash stopped this command after ${duration(timeout)}, ${given}, and ended everything it started. ` +
            `Narrow the command, or give a timeout of up to ${duration(BASH_TIMEOUT_CAP_SECONDS)}.` }] };
      }
    }
  }))] });
}
