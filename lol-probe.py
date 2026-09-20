"""Public unauthenticated endpoint probes via an isolated local Mihomo port."""
import concurrent.futures
import json
import pathlib
import socket
import ssl
import subprocess
import sys
import time
import datetime


def classify_response(code, status, body, kind, expected, error=''):
    level = '完整配置下载' if kind == 'config' else '无认证服务响应'
    result = dict(ok=False, level=level, error_class=None, tls_verified=False)
    if code:
        classes = {18: 'incomplete_download', 28: 'timeout', 60: 'tls_verify_failed',
                   35: 'tls_handshake_failed', 5: 'proxy_dns_failed', 6: 'target_dns_failed',
                   7: 'connection_failed', 56: 'connection_reset', 63: 'response_too_large', 97: 'proxy_handshake_failed'}
        failure = 'proxy_rejected' if 'CONNECT' in error and ('403' in error or '429' in error or '407' in error) else classes.get(code, 'probe_failed')
        result.update(error_class=failure, detail=f'探测未完成：{failure}（curl {code}）')
        return result
    result['tls_verified'] = status != '000'
    if status == '000' or (expected and status != str(expected)):
        result.update(error_class='unexpected_http', detail=f'收到 HTTP {status}，与预期不同；请核对服务规则，不能直接判定断网。')
        return result
    if kind == 'config':
        try:
            content = json.loads(body)
            valid = isinstance(content, dict) and bool(content) and len(body) > 10000 and status == '200'
        except (ValueError, UnicodeError):
            valid = False
        if not valid:
            result.update(error_class='invalid_json', detail='响应结束，但未通过公开配置格式检查。')
            return result
    result.update(ok=True, detail=f'HTTP {status} · {len(body)} 字节；账号和游戏流程尚未验证。')
    return result


def probe(target, proxy_port):
    started = time.monotonic()
    row = {'id': target['id'], 'name': target['label'], 'host': target['host'],
           'port': target['port'], 'ok': False, 'kind': target['probe'],
           'level': '目标 TLS' if target['probe'] == 'tls' else '服务响应',
           'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        if target['probe'] == 'tls':
            destination = ('127.0.0.1', proxy_port) if proxy_port else (target['host'], int(target['port']))
            with socket.create_connection(destination, 6) as connection:
                connection.settimeout(6)
                endpoint = f"{target['host']}:{target['port']}"
                if proxy_port:
                    connection.sendall(f'CONNECT {endpoint} HTTP/1.1\r\nHost: {endpoint}\r\n\r\n'.encode())
                    header = b''
                    while b'\r\n\r\n' not in header and len(header) < 8192:
                        part = connection.recv(1)
                        if not part:
                            raise ConnectionError('代理提前关闭连接')
                        header += part
                    if b' 200 ' not in header.split(b'\r\n', 1)[0]:
                        raise ConnectionError('代理拒绝该目标端口')
                with ssl.create_default_context().wrap_socket(connection, server_hostname=target['host']) as secured:
                    row.update(ok=True, tls_verified=True, detail=secured.version() + '；证书验证通过，未发送账号信息')
        else:
            host = target['host']
            authority = f'[{host}]' if ':' in host else host
            url = target.get('url') or f"https://{authority}:{target['port']}/"
            routing = ['--proxy', f'http://127.0.0.1:{proxy_port}', '--noproxy', ''] if proxy_port else ['--noproxy', '*']
            process = subprocess.run(['curl.exe'] + routing + ['--connect-timeout', '6', '--max-time', '15',
                '--max-filesize', '10485760', '-sS', '-w', '\n%{http_code} %{size_download}', url],
                capture_output=True, timeout=19)
            body, _, metrics = process.stdout.rpartition(b'\n')
            parts = metrics.decode(errors='replace').split()
            status = parts[0] if parts else '000'
            row.update(http=status, bytes=len(body), curl_exit=process.returncode)
            row.update(classify_response(process.returncode, status, body, target['probe'], target.get('expected'), process.stderr.decode(errors='replace')))
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        row['detail'] = type(exc).__name__ + '：探测未完成'
        row['error_class'] = 'tls_verify_failed' if isinstance(exc, ssl.SSLCertVerificationError) else 'timeout' if isinstance(exc, (TimeoutError, subprocess.TimeoutExpired)) else 'connection_or_probe_failed'
        row['tls_verified'] = False
    row['seconds'] = round(time.monotonic() - started, 2)
    return row


if __name__ == '__main__':
    request = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(lambda t: probe(t, request.get('port')), request['targets']))
    print(json.dumps({'passed': bool(rows) and all(r['ok'] for r in rows), 'rows': rows}, ensure_ascii=True))
