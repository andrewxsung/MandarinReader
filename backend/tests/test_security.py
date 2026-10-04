from app.services.security import hash_password, hash_token, new_token, verify_password


def test_password_roundtrip():
    h = hash_password("correct horse battery")
    assert h != "correct horse battery"
    assert h.startswith("$argon2id$")
    assert verify_password(h, "correct horse battery") is True


def test_wrong_password_rejected():
    h = hash_password("right")
    assert verify_password(h, "wrong") is False


def test_garbage_hash_rejected_not_raised():
    assert verify_password("not-a-hash", "anything") is False


def test_tokens_are_unique_and_hashed_deterministically():
    t1, t2 = new_token(), new_token()
    assert t1 != t2
    assert len(t1) >= 40
    assert hash_token(t1) == hash_token(t1)
    assert hash_token(t1) != hash_token(t2)
    assert len(hash_token(t1)) == 64  # sha256 hex
