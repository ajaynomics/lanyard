import { createModels } from '@earendil-works/pi-ai/models';
import { fauxProvider, fauxAssistantMessage, fauxToolCall, fauxText } from '@earendil-works/pi-ai/providers/faux';
export { fauxAssistantMessage, fauxToolCall, fauxText };
// options.model: extra fields of the scripted model (for example contextWindow).
export function scriptedProvider(responses, { model: modelOptions, ...options } = {}) {
  const faux = fauxProvider({ provider: 'fixture', models: [{ id: 'scripted', reasoning: true, input: ['text', 'image'], ...modelOptions }], ...options });
  faux.setResponses(responses);
  const models = createModels();
  models.setProvider(faux.provider);
  return { models, model: { provider: 'fixture', modelId: 'scripted' }, faux };
}
