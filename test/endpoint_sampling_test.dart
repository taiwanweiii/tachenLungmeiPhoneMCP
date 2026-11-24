import 'package:curtain_mcp_flutter/models/endpoint_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  EndpointModel sample({
    OpenAiProfile profile = OpenAiProfile.generic,
    bool sendTemperature = true,
    double? topP,
    int? maxTokens,
    String? reasoningEffort,
    String? verbosity,
    bool? enableThinking,
  }) {
    return EndpointModel(
      id: '1',
      name: 'n',
      host: 'h',
      port: 443,
      model: 'm',
      provider: LlmProvider.openai,
      profile: profile,
      sendTemperature: sendTemperature,
      topP: topP,
      maxTokens: maxTokens,
      reasoningEffort: reasoningEffort,
      verbosity: verbosity,
      enableThinking: enableThinking,
    );
  }

  test('既有端點是通用模式，只送溫度 0.1', () {
    final loaded = EndpointModel.fromJson({
      'id': 'default',
      'name': '預設',
      'host': 'integrate.api.nvidia.com',
      'port': 443,
      'model': 'nvidia/nemotron-3.5-bolt-e4b',
      'provider': 'openai',
    });
    expect(loaded.profile, OpenAiProfile.generic);
    expect(loaded.openAiSamplingBody(), {'temperature': 0.1});
  });

  test('通用模式送 max_tokens 與思考開關', () {
    final body = sample(
      sendTemperature: false,
      topP: 0.95,
      maxTokens: 1024,
      reasoningEffort: 'low',
      verbosity: 'low',
      enableThinking: false,
    ).openAiSamplingBody();

    expect(body, {
      'top_p': 0.95,
      'max_tokens': 1024,
      'chat_template_kwargs': {'enable_thinking': false},
    });
  });

  test('GPT 模式送 max_completion_tokens，不送通用欄位', () {
    final body = sample(
      profile: OpenAiProfile.gpt,
      sendTemperature: false,
      topP: 0.95,
      maxTokens: 1024,
      reasoningEffort: 'low',
      verbosity: 'low',
      enableThinking: false,
    ).openAiSamplingBody();

    expect(body, {
      'max_completion_tokens': 1024,
      'reasoning_effort': 'low',
      'verbosity': 'low',
    });
  });

  test('舊的上限欄位名稱會當成 GPT', () {
    final loaded = EndpointModel.fromJson({
      'id': '1',
      'name': 'n',
      'host': 'api.openai.com',
      'port': 443,
      'model': 'gpt-4o-mini',
      'provider': 'openai',
      'tokenField': 'maxCompletionTokens',
    });
    expect(loaded.profile, OpenAiProfile.gpt);
  });

  test('gpt-6-luna 帶工具時要明確送 reasoning_effort none', () {
    expect(EndpointModel.modelNeedsReasoningNone('gpt-6-luna'), isTrue);
    expect(EndpointModel.modelNeedsReasoningNone('GPT‑6 Luna'), isTrue);

    final body = sample(
      profile: OpenAiProfile.gpt,
      reasoningEffort: 'low',
      maxTokens: 256,
    ).openAiSamplingBody(forceReasoningNone: true);

    expect(body['reasoning_effort'], 'none');
    expect(body['max_completion_tokens'], 256);
  });

  test('被拒絕的溫度與 top_p 可以從這一次請求拿掉', () {
    final body = sample(topP: 0.5).openAiSamplingBody(
      includeTemperature: false,
      includeTopP: false,
    );
    expect(body, isEmpty);
  });
}
