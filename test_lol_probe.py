import importlib.util
import pathlib
import unittest
import datetime
import http.server
import ssl
import tempfile
import threading
import subprocess
from unittest import mock

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False

spec = importlib.util.spec_from_file_location('probe', pathlib.Path(__file__).with_name('lol-probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class ResultTests(unittest.TestCase):
    def classify(self, code=0, status='200', body=b'{"data": true}', kind='http', expected='200', error=''):
        return probe.classify_response(code, status, body, kind, expected, error)

    def test_partial_content_not_success(self):
        self.assertTrue(hasattr(probe, 'classify_response'), 'layered probe classifier missing')
        r = self.classify(code=18, body=b'{"truncated":')
        self.assertFalse(r['ok'])
        self.assertEqual(r['error_class'], 'incomplete_download')

    def test_certificate_error(self):
        r = self.classify(code=60)
        self.assertEqual(r['error_class'], 'tls_verify_failed')
        self.assertFalse(r['tls_verified'])

    def test_401_is_not_login_success(self):
        r = self.classify(status='401', expected='401')
        self.assertTrue(r['ok'])
        self.assertEqual(r['level'], '无认证服务响应')

    def test_wrong_http_not_network_down(self):
        r = self.classify(status='403')
        self.assertEqual(r['error_class'], 'unexpected_http')
        self.assertTrue(r['tls_verified'])

    def test_config_json_invalid(self):
        r = self.classify(kind='config', body=b'x'*20000)
        self.assertFalse(r['ok'])
        self.assertEqual(r['error_class'], 'invalid_json')

    def test_no_credentials_in_errors(self):
        r = self.classify(code=7, error='CONNECT failed; password=DO_NOT_EXPORT')
        self.assertNotIn('DO_NOT_EXPORT', str(r))

@unittest.skipUnless(HAS_CRYPTO, 'optional cryptography needed for local TLS fixture')
class LocalTlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now-datetime.timedelta(minutes=1))
                .not_valid_after(now+datetime.timedelta(days=1))
                .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), False)
                .sign(key, hashes.SHA256()))
        cls.cert = pathlib.Path(cls.tmp.name)/'cert.pem'
        cls.cert.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        keypath = pathlib.Path(cls.tmp.name)/'key.pem'
        keypath.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(403 if self.path == '/denied' else 200)
                self.send_header('Content-Length', '1000' if self.path == '/partial' else '2')
                self.end_headers()
                self.wfile.write(b'{}')
                self.close_connection = True
            def log_message(self, *args):
                pass
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(cls.cert), str(keypath))
        cls.server.socket = ctx.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.tmp.cleanup()

    def run_probe(self, path, trusted=True):
        port = self.server.server_port
        target = dict(id='fixture', label='fixture', host='localhost', port=port,
                      probe='http', expected='200', url=f'https://localhost:{port}{path}')
        run = subprocess.run
        def local_ca(args, **kwargs):
            return run(args+['--cacert', str(self.cert)], **kwargs)
        if trusted:
            with mock.patch.object(probe.subprocess, 'run', local_ca):
                return probe.probe(target, None)
        return probe.probe(target, None)

    def test_actual_truncated_https_response(self):
        r = self.run_probe('/partial')
        # curl TLS backends report either partial transfer (18) or abrupt TLS close (56).
        self.assertIn(r['error_class'], ('incomplete_download', 'connection_reset'), r)
        self.assertFalse(r['ok'])

    def test_actual_untrusted_certificate(self):
        r = self.run_probe('/', trusted=False)
        self.assertEqual(r['error_class'], 'tls_verify_failed', r)

    def test_actual_tls_success_business_failure(self):
        r = self.run_probe('/denied')
        self.assertEqual(r['error_class'], 'unexpected_http', r)
        self.assertTrue(r['tls_verified'])
        self.assertFalse(r['ok'])

if __name__ == '__main__':
    unittest.main()
