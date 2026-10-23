// Ошибки, которые сервер возвращает клиенту. code — машинное имя, message — текст для пользователя.

export class AppError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const badRequest = (message, code = 'bad_request') => new AppError(400, code, message);
export const unauthorized = (message = 'Нужно войти в приложение') => new AppError(401, 'unauthorized', message);
export const forbidden = (message = 'Недостаточно прав') => new AppError(403, 'forbidden', message);
export const notFound = (message = 'Не найдено') => new AppError(404, 'not_found', message);
export const conflict = (message, code = 'conflict') => new AppError(409, code, message);
export const tooMany = (message) => new AppError(429, 'too_many_requests', message);
export const upstream = (message) => new AppError(502, 'payment_provider_error', message);
