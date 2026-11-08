"""Evidence checks and per-sentence invariants. Model labels never authorize movement."""
import re
import unicodedata
from datetime import datetime, timezone


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def fresh(value, now, seconds):
    return value is not None and -2 <= (now - utc(value)).total_seconds() <= seconds


def normalize(text):
    return re.sub(r"\s+", " ", "".join(c for c in unicodedata.normalize("NFD", text.lower())
        if not unicodedata.combining(c) and unicodedata.category(c) != "Cf").replace("đ", "d"))


def current_context(context, has_image=False, now=None):
    """Recheck at every model round, tool read and response, including queue latency."""
    now = now or datetime.now(timezone.utc)
    gps = (fresh(context.gps_updated_at, now, 15) and context.position is not None
           and context.accuracy_meters is not None and 0 < context.accuracy_meters <= 25
           and context.status != "poorGps")
    yolo = fresh(context.yolo_updated_at, now, 5)
    camera = has_image and fresh(context.image_captured_at, now, 10)
    heading = fresh(context.heading_updated_at, now, 10) and context.heading_degrees is not None
    navigation = (gps and context.status == "navigating" and context.destination is not None
                  and (context.heading_updated_at is None or heading))
    clean = context.model_copy(deep=True)
    if not gps:
        clean.position = None
        clean.street_name = ""
    if not yolo:
        clean.obstacles = []
        clean.yolo_updated_at = None
    if not camera: clean.image_captured_at = None
    if not heading: clean.heading_degrees = None
    if not navigation:
        clean.target_bearing = None
        clean.next_instructions = []
        clean.next_maneuver_meters = None
        clean.next_maneuver_type = None
        clean.route_message = "Chưa có chỉ dẫn tuyến hiện tại đủ dữ liệu vị trí. Hãy kiểm tra GPS và tuyến."
    sources = {"gps": gps, "yolo": yolo, "camera": camera, "heading": heading,
               "navigation": navigation, "user": True}
    return clean, sources


PRECAUTIONS = {
    "stop_and_check": "Bạn nên dừng lại để kiểm tra vật cản và khoảng trống xung quanh.",
    "verify_position": "Hãy kiểm tra vị trí, chờ GPS ổn định hoặc nhờ người hỗ trợ xác định vị trí.",
    "check_signal": "Hãy kiểm tra vị trí điểm sang đường và tín hiệu giao thông trước khi quyết định.",
    "ask_assistance": "Nếu chưa xác định được lối đi, hãy nhờ người xung quanh hỗ trợ.",
    "request_route_refresh": "Bạn có thể yêu cầu cập nhật tuyến; thao tác cần được xác nhận trong ứng dụng.",
}
NAMES = {"person": "người", "motorcycle": "xe máy", "car": "ô tô", "bicycle": "xe đạp",
         "bus": "xe buýt", "truck": "xe tải", "chair": "ghế", "bench": "ghế dài", "dog": "chó",
         "backpack": "ba lô", "suitcase": "va li"}
POSITIONS = {"left": "bên trái", "center": "giữa", "right": "bên phải"}


def situation_context(context, has_image=False, now=None):
    clean, sources = current_context(context, has_image, now)
    groups = {p: {} for p in POSITIONS}
    for obstacle in clean.obstacles:
        category = ("person" if obstacle.class_name == "person" else "vehicle" if obstacle.class_name in
                    {"bicycle", "motorcycle", "car", "bus", "truck"} else "obstacle" if obstacle.class_name in
                    {"chair", "bench", "backpack", "suitcase"} else "other")
        key = (obstacle.class_name, category)
        groups[obstacle.position][key] = groups[obstacle.position].get(key, 0) + 1
    detections = [{"position": p, "class_name": name, "category": category, "count": count}
                  for p, group in groups.items() for (name, category), count in sorted(group.items())]
    observations = [f"YOLO: {d['count']} {NAMES.get(d['class_name'], 'đối tượng')} ở {POSITIONS[d['position']]} khung hình."
                    for d in detections]
    uncertainty = ["Không đo độ sâu, vận tốc, khoảng trống hay quyền sang đường.",
                   "Chưa đăng ký hình học camera với hướng tuyến; đối tượng giữa ảnh không chứng minh chắn tuyến."]
    if not sources['gps']: uncertainty.append("GPS thiếu, cũ hoặc sai số lớn; không xác định vị trí chính xác.")
    if sources['yolo'] and not detections: uncertainty.append("Không có detection không chứng minh đường trống.")
    return {"timestamp": clean.captured_at.isoformat(), "navigation_state": clean.status,
        "gps_state": {"fresh": sources['gps'], "accuracy_meters": clean.accuracy_meters},
        "route_context": {"message": clean.route_message, "next_instructions": clean.next_instructions,
            "maneuver_type": clean.next_maneuver_type, "maneuver_meters": clean.next_maneuver_meters},
        "detections": detections, "observations": observations,
        "relevant_changes": clean.situation_changes, "watch_category": clean.watch_category,
        "source_freshness": sources, "uncertainty": uncertainty}


def unsupported(sentence):
    # A limitation in one clause cannot launder a positive permission in another.
    return any(_unsupported_clause(clause) for clause in re.split(
        r"\b(?:nhưng|tuy nhiên|however|but)\b|,\s+|;\s*|\bvà\s+(?=(?:bạn|hãy|cứ)\b)", sentence, flags=re.IGNORECASE))


def _unsupported_clause(sentence):
    """Narrow claim patterns, applied to every free-text field regardless of kind/sources.

    This is defense in depth, not a natural-language proof. No AI text becomes a
    navigation command. Negative uncertainty and explanations remain speakable.
    """
    n = normalize(sentence).strip(" \"“”")
    definition = bool(re.search(r"^(?:re (?:trai|phai)|di thang) (?:la|co nghia)", n))
    uncertainty = bool(re.search(r"chua (?:the |du )?(?:xac (?:nhan|dinh)|biet|do)|khong (?:the |duoc |nen )?(?:xac nhan|xac dinh|suy ra|ket luan|dam bao)|cannot (?:confirm|determine)", n))
    # Assertions of clearance/safety/permission; a negative limitation is allowed.
    safety_claim = re.search(
        r"(?:phia truoc|ben trai|ben phai|duong(?: nay)?|loi(?: di)?|khu vuc(?: nay)?|cho nay|noi nay|o day|moi thu|path|road|crossing|you|ban) "
        r"(?:(?:da|dang|la|rat|hoan toan|deu|van|is|are|now) )*(?:an toan|safe|khong nguy hiem|trong|thong thoang|clear)"
        r"|(?:an toan|safe) (?:de|to) (?:di|sang|qua|re|walk|cross|move|proceed)"
        r"|^\s*(?:an toan|safe)[.!]?\s*$|clear path|duong trong|loi trong"
        r"|^(?:chac chan|hoan toan|rat) (?:an toan|safe)"
        r"|(?:toi|camera|yolo|he thong) (?:da )?(?:xac nhan|dam bao).{0,30}(?:an toan|safe)"
        r"|khong (?:co|thay|phat hien) (?:xe|o to|vat can|chuong ngai)", n)
    if safety_claim and not uncertainty: return True
    # Imperatives/permissions, not occurrences of direction words in explanations.
    if re.search(r"(?:^|[,;:]\s*|\b(?:ban|hay|nen|cu|co the|duoc phep|tiep tuc)\s+)(?:di thang|di tiep|di ngay|di chuyen|re (?:trai|phai)|quay sang|buoc sang|ne sang|lach sang|sang duong|qua duong|bang qua|tiep tuc di|di ve ben)|\b(?:go ahead|proceed|you (?:may|can) (?:walk|move|cross)|turn (?:left|right) now)\b", n) and not uncertainty and not definition:
        return True
    # No depth, object velocity, traversability or signal verification exists here.
    physical = bool(re.search(r"xe|nguoi|vat can|phia truoc|khoang cach|cach (?:ban|toi)|vehicle|car |distance", n))
    if ((physical and re.search(r"\b\d+(?:[.,]\d+)?\s*(?:m\b|met\b|meters?\b|km/?h)|(?:cach|khoang cach).*(?:met|buoc)", n)) or
        re.search(r"rat gan|(?:xe|nguoi).{0,20}dang (?:lao|tien|chay|di chuyen|re)|co the (?:di qua|vuot qua)|du (?:cho|rong) de|^den (?:dang )?xanh[.!]?$|den (?:dang )?xanh (?:nen|roi|ban|co the)", n)) and not uncertainty:
        return True
    return False


def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+|\n+", text.strip()) if s.strip()]


def accepted_sentences(text):
    result, rejected = [], False
    for sentence in sentences(text):
        if not unsupported(sentence):
            result.append(sentence)
            continue
        rejected = True
        # Keep a complete visual observation before an unsupported movement clause.
        prefix = sentence.split(',')[0].strip()
        if prefix != sentence and re.match(r"(?:trong anh co|camera (?:ghi nhan|phat hien)|yolo (?:ghi nhan|phat hien)|toi thay)\b", normalize(prefix)) and not unsupported(prefix):
            result.append(prefix.rstrip('.!?') + '.')
    return result, rejected


def visual_claim(text):
    n = normalize(text)
    return bool(re.search(r"trong anh|khung hinh|phia truoc (?:co|la)|ben (?:trai|phai) (?:co|la)|toi (?:thay|nhin thay)|toi khong thay|^co (?:xe|nguoi|o to|vat can)|(?:xe|nguoi|vat can|o to).{0,15}(?:chan loi|nam o|o ben|phia truoc|dang chay)", n))


def render_guidance(answer, context, has_image, now=None):
    now = now or datetime.now(timezone.utc)
    clean, available = current_context(context, has_image, now)
    observations, interpretation, used, rejected = [], [], set(), False
    if answer.kind == "route_status":
        text = "Chỉ dẫn do bộ dẫn đường cung cấp: " + clean.route_message
        return text, {"kind": "route_status", "observations": [], "interpretation": [],
            "recommendations": [], "evidence_sources": ["navigation"] if available["navigation"] else [],
            "confidence": "reported" if available["navigation"] else "unknown",
            "priority": 1, "requires_confirmation": False,
            "expires_at": min(now.timestamp() + 5, utc(context.gps_updated_at).timestamp() + 15)
                if available['navigation'] else now.timestamp() + 15}

    for group, target in ((answer.observations, observations), (answer.interpretation, interpretation)):
        for statement in group:
            valid = bool(statement.sources) and all(available[s] for s in statement.sources)
            if not valid:
                rejected = True
                continue
            if target is observations and 'camera' not in statement.sources and statement.sources != ['user']:
                # Presence of a source is not proof that an arbitrary model claim matches it.
                if 'yolo' in statement.sources:
                    observations.extend(situation_context(context, has_image, now)['observations'][:2])
                if 'gps' in statement.sources:
                    observations.append(f"GPS báo sai số khoảng {clean.accuracy_meters:g} mét.")
                if 'heading' in statement.sources:
                    observations.append(f"La bàn báo hướng điện thoại {clean.heading_degrees:g} độ.")
                if 'navigation' in statement.sources:
                    observations.append('Bộ dẫn đường báo: ' + clean.route_message)
                used.update(statement.sources)
                if any(unsupported(s) for s in sentences(statement.text)): rejected = True
                continue
            kept, removed = accepted_sentences(statement.text)
            rejected |= removed
            for sentence in kept:
                if visual_claim(sentence) and not set(statement.sources) & {'camera', 'yolo', 'user'}:
                    rejected = True
                    continue
                # User reports are not independent camera evidence.
                target.append(("Nếu đúng như tình huống bạn nêu: " if statement.sources == ["user"] else "") + sentence)
                used.update(statement.sources)

    general = []
    kept, removed = accepted_sentences(answer.text)
    rejected |= removed
    for sentence in kept:
        n = normalize(sentence)
        environmental = visual_claim(sentence)
        if environmental and not (available["camera"] or available["yolo"]):
            rejected = True
            continue
        if environmental:
            used.add("camera" if available["camera"] else "yolo")
            if not available['camera']:
                observations.extend(situation_context(context, has_image, now)['observations'][:2])
                continue
        general.append(sentence)

    recommendations = [PRECAUTIONS[r] for r in answer.recommendations]
    if rejected and not observations and clean.obstacles:
        groups = sorted({(o.class_name, o.position) for o in clean.obstacles})[:3]
        observations.append("YOLO ghi nhận " + ", ".join(f"{NAMES.get(c, 'đối tượng')} ở {POSITIONS[p]} khung hình" for c, p in groups) + ".")
        used.add("yolo")
    if rejected:
        interpretation.append("Tôi chưa thể xác nhận khoảng cách, khoảng trống hoặc điều kiện di chuyển.")
        if not recommendations: recommendations.append(PRECAUTIONS["stop_and_check"])
    pieces = observations[:1] + interpretation[:1] + recommendations[:2] + general
    if not pieces: pieces = ["Chưa đủ dữ liệu hiện tại. Bạn muốn tôi kiểm tra thông tin nào?"]
    limitation = "Quan sát camera chỉ bao phủ khung hình, không xác nhận an toàn di chuyển." if used & {"camera", "yolo"} else ""
    # Preserve complete sentences and the evidence limitation; do not cut a warning mid-clause.
    text = ""
    for piece in dict.fromkeys(pieces):
        if len(text) + len(piece) + 1 <= 779 - len(limitation): text = (text + ' ' + piece).strip()
    if limitation: text = (text + ' ' + limitation).strip()
    expiries = [now.timestamp() + 15]
    for source, timestamp, ttl in (("yolo", context.yolo_updated_at, 5), ("camera", context.image_captured_at, 10),
                                    ("gps", context.gps_updated_at, 15), ("heading", context.heading_updated_at, 10)):
        if source in used and timestamp: expiries.append(utc(timestamp).timestamp() + ttl)
    priority = 2 if clean.obstacles else 1 if context.status in {"poorGps", "offRoute", "error"} else 0
    return text, {"kind": answer.kind, "observations": observations, "interpretation": interpretation,
        "recommendations": recommendations, "evidence_sources": sorted(used), "confidence": "limited" if used else "unknown",
        "requires_confirmation": False, "priority": priority, "expires_at": min(expiries),
        "precaution_expires_at": now.timestamp() + 15 if recommendations else None}


def speech_summary(text, guidance):
    if len(text) <= 320: return text
    parts = guidance['observations'][:1] + guidance['recommendations'][:1] + guidance['interpretation'][:1]
    if not parts: parts = sentences(text)[:2]
    limitation = 'Chưa xác minh khoảng trống hoặc điều kiện di chuyển.' if set(guidance['evidence_sources']) & {'camera', 'yolo'} else ''
    result = ''
    for part in parts:
        if len(result) + len(part) + 1 <= 319 - len(limitation): result = (result + ' ' + part).strip()
    if limitation: result = (result + ' ' + limitation).strip()
    return result or 'Chưa đủ thông tin; hãy kiểm tra tình huống hiện tại.'
