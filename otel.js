import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';
import { BatchLogRecordProcessor, LoggerProvider } from '@opentelemetry/sdk-logs';
import { Resource } from '@opentelemetry/resources';
import { SemanticResourceAttributes } from '@opentelemetry/semantic-conventions';
import { logs, SeverityNumber } from '@opentelemetry/api-logs';

// ---------------------------------------------------------------------------
// OTEL Logging Setup
// ---------------------------------------------------------------------------

const resource = new Resource({
  [SemanticResourceAttributes.SERVICE_NAME]: 'dev-blog-app',
  [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: process.env.NODE_ENV || 'development',
});

const exporter = new OTLPLogExporter(); // Defaults to OTEL_EXPORTER_OTLP_ENDPOINT
const loggerProvider = new LoggerProvider({ resource });
loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(exporter));

// Set as global logger provider
logs.setGlobalLoggerProvider(loggerProvider);

const logger = logs.getLogger('dev-blog-app');

// Monkey-patch console to send logs to OTEL
const originalLog = console.log;
const originalError = console.error;
const originalWarn = console.warn;
const originalInfo = console.info;

console.log = (...args) => {
  logger.emit({
    severityNumber: SeverityNumber.INFO,
    severityText: 'INFO',
    body: args.map(arg => (typeof arg === 'object' ? JSON.stringify(arg) : arg)).join(' '),
  });
  if (process.env.DISABLE_GCP_LOGGING !== 'true') {
    originalLog(...args);
  }
};

console.info = (...args) => {
  logger.emit({
    severityNumber: SeverityNumber.INFO,
    severityText: 'INFO',
    body: args.map(arg => (typeof arg === 'object' ? JSON.stringify(arg) : arg)).join(' '),
  });
  if (process.env.DISABLE_GCP_LOGGING !== 'true') {
    originalInfo(...args);
  }
};

console.warn = (...args) => {
  logger.emit({
    severityNumber: SeverityNumber.WARN,
    severityText: 'WARN',
    body: args.map(arg => (typeof arg === 'object' ? JSON.stringify(arg) : arg)).join(' '),
  });
  if (process.env.DISABLE_GCP_LOGGING !== 'true') {
    originalWarn(...args);
  }
};

console.error = (...args) => {
  logger.emit({
    severityNumber: SeverityNumber.ERROR,
    severityText: 'ERROR',
    body: args.map(arg => (typeof arg === 'object' ? JSON.stringify(arg) : arg)).join(' '),
  });
  if (process.env.DISABLE_GCP_LOGGING !== 'true') {
    originalError(...args);
  }
};

// Initialize SDK for traces/metrics
const sdk = new NodeSDK({
  resource,
  // Using logRecordProcessor here might be redundant if we use loggerProvider directly,
  // but it's good for future-proofing traces/metrics.
});

sdk.start();

// Handle shutdown
process.on('SIGTERM', async () => {
  try {
    await loggerProvider.forceFlush();
    await sdk.shutdown();
    originalLog('OTEL SDK shut down');
  } catch (error) {
    originalError('Error shutting down OTEL SDK', error);
  } finally {
    process.exit(0);
  }
});
