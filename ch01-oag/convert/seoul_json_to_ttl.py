#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
서울시 실시간 도시데이터(인구) JSON -> RDF/Turtle(.ttl) 온톨로지 변환 스크립트
- 단일 및 복합 지역(여러 개 지역 데이터) 지원
- 다중 입력 JSON 파일 지원
"""

import argparse
import json
import os
import re
import shutil
import sys
from datetime import datetime
from rdflib import Graph, Namespace, URIRef, Literal
from rdflib.namespace import RDF, RDFS, XSD

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
def yn_to_bool(v):
    if v is None:
        return None
    s = str(v).strip().upper()
    if s in ("Y", "YES", "TRUE", "T", "1"):
        return True
    if s in ("N", "NO", "FALSE", "F", "0"):
        return False
    return None

def to_int(x):
    try:
        if x is None or x == "":
            return None
        return int(str(x).replace(",", ""))
    except Exception:
        return None

def to_float(x):
    try:
        if x is None or x == "":
            return None
        return float(str(x).replace(",", ""))
    except Exception:
        return None

def is_dt_like(s: str) -> bool:
    s = str(s)
    return bool(re.match(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?$", s))

def to_iso_datetime(s):
    if not s:
        return None
    s = str(s).strip()
    try:
        if "T" in s:
            return s
        if len(s) == 16:
            dt = datetime.strptime(s, "%Y-%m-%d %H:%M")
            return dt.isoformat()
        elif len(s) == 19:
            dt = datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
            return dt.isoformat()
        else:
            return s.replace(" ", "T")
    except Exception:
        return s.replace(" ", "T")

def slugify(s):
    if s is None:
        return None
    s = re.sub(r"\s+", "-", s.strip())
    s = re.sub(r"[^0-9A-Za-z\-가-힣_]", "", s)
    return s

def condense_time(iso_t: str) -> str:
    return re.sub(r"[-:]", "", iso_t)

def literal_guess(val):
    if isinstance(val, bool):
        return Literal(val, datatype=XSD.boolean)
    if isinstance(val, int):
        return Literal(val, datatype=XSD.integer)
    if isinstance(val, float):
        return Literal(val, datatype=XSD.decimal)
    s = str(val)
    b = yn_to_bool(s)
    if b is not None:
        return Literal(b, datatype=XSD.boolean)
    i = to_int(s)
    if i is not None and str(i) == s.replace(",", ""):
        return Literal(i, datatype=XSD.integer)
    f = to_float(s)
    if f is not None:
        return Literal(f, datatype=XSD.decimal)
    if is_dt_like(s):
        return Literal(to_iso_datetime(s), datatype=XSD.dateTime)
    return Literal(s)

def norm_key(k: str) -> str:
    k = k.strip().replace(".", "_")
    k = re.sub(r"\W+", "_", k, flags=re.UNICODE)
    k = re.sub(r"_+", "_", k).strip("_")
    return k.lower()

def add_kv_all(g: Graph, subj, EX, item: dict, known: set, prefix: str, keep_raw_json: bool):
    for k, v in item.items():
        if k in known:
            continue
        nk = norm_key(k)
        pred = EX[f"{prefix}{nk}"]
        if isinstance(v, (str, int, float, bool)) or v is None:
            if v is None:
                continue
            g.add((subj, pred, literal_guess(v)))
        elif isinstance(v, (list, dict)):
            if keep_raw_json:
                jpred = EX[f"json_{nk}"]
                g.add((subj, jpred, Literal(json.dumps(v, ensure_ascii=False))))
        else:
            g.add((subj, pred, Literal(str(v))))
    return g

# ------------------------------------------------------------------------------
# 단일 장소(Place) 데이터 모델링 처리
# ------------------------------------------------------------------------------
def process_place_item(
    g: Graph,
    EX: Namespace,
    item: dict,
    result: dict,
    label_lang: str,
    keep_raw_json: bool,
    place_code_override: str = None
) -> int:
    area_nm = item.get("AREA_NM")
    area_cd = place_code_override or item.get("AREA_CD") or slugify(area_nm) or "unknown"

    # Place 인스턴스
    place_local = f"place_{area_cd}"
    place_uri = EX[place_local]
    g.add((place_uri, RDF.type, EX.Place))
    if area_nm:
        g.add((place_uri, RDFS.label, Literal(area_nm, lang=label_lang)))
    g.add((place_uri, EX["iri"], Literal(str(place_uri))))

    known_place = set()
    def add_know(subj, pred, key, cast=None):
        known_place.add(key)
        val = item.get(key)
        if val is None:
            return
        if cast == "dt":
            g.add((subj, pred, Literal(to_iso_datetime(val), datatype=XSD.dateTime)))
        elif cast == "int":
            iv = to_int(val)
            if iv is not None:
                g.add((subj, pred, Literal(iv, datatype=XSD.integer)))
        elif cast == "float":
            fv = to_float(val)
            if fv is not None:
                g.add((subj, pred, Literal(fv, datatype=XSD.decimal)))
        elif cast == "bool":
            bv = yn_to_bool(val)
            if bv is not None:
                g.add((subj, pred, Literal(bv, datatype=XSD.boolean)))
        else:
            g.add((subj, pred, Literal(val)))

    add_know(place_uri, EX.areaCode, "AREA_CD")
    add_know(place_uri, EX.hasCongestionLevel, "AREA_CONGEST_LVL")
    add_know(place_uri, EX.congestionMessage, "AREA_CONGEST_MSG")
    add_know(place_uri, EX.populationMin, "AREA_PPLTN_MIN", "int")
    add_know(place_uri, EX.populationMax, "AREA_PPLTN_MAX", "int")
    add_know(place_uri, EX.maleRate, "MALE_PPLTN_RATE", "float")
    add_know(place_uri, EX.femaleRate, "FEMALE_PPLTN_RATE", "float")
    for age in ("0", "10", "20", "30", "40", "50", "60", "70"):
        k_age = f"PPLTN_RATE_{age}"
        known_place.add(k_age)
        v = item.get(k_age)
        if v is not None:
            fv = to_float(v)
            if fv is not None:
                g.add((place_uri, EX[f"ageRate_{age}"], Literal(fv, datatype=XSD.decimal)))
            else:
                g.add((place_uri, EX[f"ageRate_{age}"], Literal(v)))
    add_know(place_uri, EX.residentRate, "RESNT_PPLTN_RATE", "float")
    add_know(place_uri, EX.nonResidentRate, "NON_RESNT_PPLTN_RATE", "float")
    add_know(place_uri, EX.asOf, "PPLTN_TIME", "dt")
    add_know(place_uri, EX["replace"], "REPLACE_YN", "bool")
    add_know(place_uri, EX.hasForecast, "FCST_YN", "bool")

    add_kv_all(g, place_uri, EX, item, known_place, prefix="attr_", keep_raw_json=keep_raw_json)

    # Forecasts (예측 인스턴스)
    fc_list = item.get("FCST_PPLTN") or []
    for fc in fc_list:
        known_fc = {"FCST_TIME", "FCST_CONGEST_LVL", "FCST_PPLTN_MIN", "FCST_PPLTN_MAX"}
        t = fc.get("FCST_TIME")
        iso_t = to_iso_datetime(t) if t else None
        safe_t = condense_time(iso_t) if iso_t else "unknown"
        f_local = f"forecast_{area_cd}_{safe_t}"
        f_uri = EX[f_local]
        g.add((f_uri, RDF.type, EX.Forecast))
        g.add((f_uri, EX.forPlace, place_uri))
        if iso_t:
            g.add((f_uri, EX.forecastTime, Literal(iso_t, datatype=XSD.dateTime)))
        v = fc.get("FCST_CONGEST_LVL")
        if v is not None:
            g.add((f_uri, EX.forecastCongestionLevel, Literal(v)))
        vmn = to_int(fc.get("FCST_PPLTN_MIN"))
        if vmn is not None:
            g.add((f_uri, EX.forecastPopulationMin, Literal(vmn, datatype=XSD.integer)))
        vmx = to_int(fc.get("FCST_PPLTN_MAX"))
        if vmx is not None:
            g.add((f_uri, EX.forecastPopulationMax, Literal(vmx, datatype=XSD.integer)))
        if area_nm and iso_t:
            human = f"{area_nm} {iso_t.replace('T', ' ')[:16]} 예측"
            g.add((f_uri, RDFS.label, Literal(human, lang=label_lang)))
        g.add((f_uri, EX["iri"], Literal(str(f_uri))))
        add_kv_all(g, f_uri, EX, fc, known_fc, prefix="fattr_", keep_raw_json=keep_raw_json)

    # Response (응답 메타데이터 인스턴스)
    if result:
        ts = to_iso_datetime(item.get("PPLTN_TIME") or "unknown")
        safe_ts = condense_time(ts) if ts else "unknown"
        r_local = f"response_{area_cd}_{safe_ts}"
        resp_uri = EX[r_local]
        g.add((resp_uri, RDF.type, EX.Response))
        g.add((resp_uri, EX["iri"], Literal(str(resp_uri))))
        for k, pred_name in [("RESULT.CODE", "resultCode"), ("RESULT.MESSAGE", "resultMessage")]:
            if k in result:
                g.add((resp_uri, EX[pred_name], literal_guess(result[k])))
        g.add((resp_uri, EX["aboutPlace"], place_uri))
        known_resp = {"RESULT.CODE", "RESULT.MESSAGE"}
        add_kv_all(g, resp_uri, EX, result, known_resp, prefix="rattr_", keep_raw_json=keep_raw_json)

    return len(fc_list)

# ------------------------------------------------------------------------------
# 메인 함수
# ------------------------------------------------------------------------------
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_input_file = (
        os.path.join(script_dir, "seoul_ppltn.json")
        if os.path.exists(os.path.join(script_dir, "seoul_ppltn.json"))
        else (
            os.path.join(script_dir, "compat.json")
            if os.path.exists(os.path.join(script_dir, "compat.json"))
            else os.path.join(script_dir, "gangnam.json")
        )
    )
    default_output_file = os.path.join(script_dir, "seoul_ppltn.ttl")

    ap = argparse.ArgumentParser(
        description="Seoul citydata_ppltn JSON → TTL (단일/복합 지역 온톨로지 변환)"
    )
    ap.add_argument("--input", nargs="+", default=[default_input_file], help="입력 JSON 파일 경로 (기본값: seoul_ppltn.json)")
    ap.add_argument("--output", default=default_output_file, help="출력 Turtle(.ttl) 파일 경로 (기본값: seoul_ppltn.ttl)")
    ap.add_argument("--base", default="http://k.fc/onto#", help="기본 온톨로지 네임스페이스 IRI")
    ap.add_argument("--place-code", default=None, help="장소 코드 재정의 (단일 지역 변환 시에만 유효)")
    ap.add_argument("--label-lang", default="ko", help="rdfs:label 언어 태그 (기본값: ko)")
    ap.add_argument("--keep-raw-json", action="store_true", help="비원자적 값을 JSON 문자열로 유지")
    args = ap.parse_args()

    EX = Namespace(args.base)
    g = Graph()
    g.bind("", EX)
    g.bind("xsd", XSD)
    g.bind("rdfs", RDFS)

    total_places = 0
    total_forecasts = 0
    places_converted = []

    for input_file in args.input:
        try:
            with open(input_file, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"[WARN] JSON 파일 읽기 실패 ({input_file}): {e}", file=sys.stderr)
            continue

        key = next((k for k in data.keys() if "citydata_ppltn" in k), None)
        if not key:
            print(f"[WARN] '{input_file}' 에서 'citydata_ppltn' 키를 찾을 수 없습니다.", file=sys.stderr)
            continue

        arr = data.get(key, [])
        if not arr:
            print(f"[WARN] '{input_file}' 의 'citydata_ppltn' 배열이 비어 있습니다.", file=sys.stderr)
            continue

        result = data.get("RESULT") or data.get("SeoulRtd.RESULT") or {}
        if "RESULT" in result:
            result = result["RESULT"]

        is_single = (len(arr) == 1 and len(args.input) == 1)

        for item in arr:
            override_code = args.place_code if is_single else None
            fc_count = process_place_item(
                g=g,
                EX=EX,
                item=item,
                result=result,
                label_lang=args.label_lang,
                keep_raw_json=args.keep_raw_json,
                place_code_override=override_code,
            )
            total_places += 1
            total_forecasts += fc_count
            nm = item.get("AREA_NM", "미상")
            cd = override_code or item.get("AREA_CD", "미상")
            places_converted.append((nm, cd, fc_count))

    if total_places == 0:
        print("[ERROR] 유효하게 변환된 지역 데이터가 없습니다.", file=sys.stderr)
        sys.exit(1)

    # 어휘 스키마 메타데이터 등록
    for term, label in [
        (EX.Place, "Place"),
        (EX.Forecast, "Forecast"),
        (EX.Response, "Response"),
        (EX.areaCode, "area code"),
        (EX.hasCongestionLevel, "congestion level"),
        (EX.congestionMessage, "congestion message"),
        (EX.populationMin, "population min"),
        (EX.populationMax, "population max"),
        (EX.maleRate, "male rate"),
        (EX.femaleRate, "female rate"),
        (EX.residentRate, "resident rate"),
        (EX.nonResidentRate, "non-resident rate"),
        (EX.asOf, "as of time"),
        (EX["replace"], "replace flag"),
        (EX.hasForecast, "has forecast flag"),
        (EX.forPlace, "for place"),
        (EX.forecastTime, "forecast time"),
        (EX.forecastCongestionLevel, "forecast congestion level"),
        (EX.forecastPopulationMin, "forecast population min"),
        (EX.forecastPopulationMax, "forecast population max"),
        (EX["resultCode"], "result code"),
        (EX["resultMessage"], "result message"),
        (EX["aboutPlace"], "about place"),
        (EX["iri"], "string form of IRI"),
    ]:
        g.add((term, RDFS.label, Literal(label)))

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(g.serialize(format="turtle"))

    # 하위 호환용 compat.ttl 및 gangnam.ttl 동기화
    output_dir = os.path.dirname(os.path.abspath(args.output))
    compat_ttl = os.path.join(output_dir, "compat.ttl")
    if os.path.abspath(args.output) != compat_ttl:
        shutil.copyfile(args.output, compat_ttl)
    gangnam_ttl = os.path.join(output_dir, "gangnam.ttl")
    if os.path.abspath(args.output) != gangnam_ttl:
        shutil.copyfile(args.output, gangnam_ttl)

    print(f"[SUCCESS] RDF 온톨로지 변환 완료:")
    print(f"  - 총 변환 장소: {total_places}개 지역")
    for nm, cd, fc_n in places_converted:
        print(f"    · [{cd}] {nm}: 예측 {fc_n}건")
    print(f"  - 총 예측 데이터: {total_forecasts}개")
    print(f"  - 총 RDF 트리플: {len(g)}개")
    print(f"  - 메인 출력 파일: {args.output}")
    print(f"  - 하위 호환 파일: {compat_ttl} (및 gangnam.ttl)")

if __name__ == "__main__":
    main()
